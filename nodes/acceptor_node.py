import json
import time
import threading
import logging
import requests
from flask import request, jsonify

from base_node import BaseNode

class Acceptor(BaseNode):
    """
    Implementação do nó Acceptor no algoritmo Paxos.
    Responsável por aceitar ou rejeitar propostas dos proposers.
    """
    
    def __init__(self, app=None):
        """
        Inicializa o nó Acceptor.
        """
        super().__init__(app)
        
        # Estado específico do acceptor
        self.highest_promised_number = 0
        self.accepted_proposal_number = 0
        self.accepted_value = None
        
        # Timeout para detecção de líderes inativos
        self.leader_timeout = 10  # segundos
    
    def _get_default_port(self):
        """Porta padrão para acceptors"""
        return 4000
    
    def _register_routes(self):
        """Registrar rotas específicas do acceptor"""
        @self.app.route('/prepare', methods=['POST'])
        def prepare():
            """Receber mensagem prepare de um proposer"""
            return self._handle_prepare(request.json)
        
        @self.app.route('/accept', methods=['POST'])
        def accept():
            """Receber mensagem accept de um proposer"""
            return self._handle_accept(request.json)
    
    def _start_threads(self):
        """Iniciar threads específicas do acceptor"""
        # Thread para verificar o status do líder
        threading.Thread(target=self._check_leader_status, daemon=True).start()
    
    def _check_leader_status(self):
        """
        Verificar periodicamente o status do líder e detectar falhas.
        Se o líder estiver inativo por muito tempo, limpar essa informação
        para permitir nova eleição.
        """
        while True:
            try:
                # Verificar líder atual
                current_leader = self.gossip.get_leader()
                
                if current_leader is not None:
                    # Verificar se o líder está ativo através de seu heartbeat
                    leader_info = self.gossip.get_node_info(str(current_leader))
                    if leader_info and leader_info.get('metadata'):
                        last_heartbeat = leader_info.get('metadata').get('last_heartbeat', 0)
                        current_time = time.time()
                        
                        # Se o último heartbeat foi há muito tempo, considerar o líder como falho
                        if current_time - last_heartbeat > self.leader_timeout:
                            self.logger.warning(f"Líder {current_leader} parece inativo. Último heartbeat: {current_time - last_heartbeat:.1f}s atrás")
                            
                            # Limpar informação de líder localmente
                            self.gossip.set_leader(None)
                            
                            # Atualizar metadata no Gossip
                            self.gossip.update_local_metadata({
                                "leader_detected_failed": current_leader,
                                "detection_time": current_time
                            })
            except Exception as e:
                self.logger.error(f"Erro ao verificar status do líder: {e}")
            
            # Verificar a cada 2 segundos
            time.sleep(2)
    
    def _handle_prepare(self, data):
        """
        Manipula requisições prepare dos proposers.
        
        Args:
            data (dict): Dados do prepare
        
        Returns:
            Response: Resposta HTTP
        """
        proposer_id = data.get('proposer_id')
        proposal_number = data.get('proposal_number')
        is_leader_election = data.get('is_leader_election', False)
        
        if not all([proposer_id, proposal_number]):
            return jsonify({"error": "Missing required information"}), 400
        
        with self.lock:
            # Para eleição de líder ou se não houver líder, ser mais permissivo
            leader_unknown = self.gossip.get_leader() is None
            
            # Se o número da proposta for maior que o prometido anteriormente, aceitar
            if proposal_number > self.highest_promised_number:
                self.highest_promised_number = proposal_number
                
                if is_leader_election:
                    self.logger.info(f"Prometido para eleição de líder com proposta {proposal_number} do proposer {proposer_id}")
                else:
                    self.logger.info(f"Prometido para proposta normal {proposal_number} do proposer {proposer_id}")
                
                return jsonify({
                    "status": "promise",
                    "accepted_proposal_number": self.accepted_proposal_number,
                    "accepted_value": self.accepted_value
                }), 200
            else:
                # Em modo bootstrap ou se não houver líder, ser mais permissivo com propostas de eleição
                if is_leader_election and leader_unknown:
                    self.logger.info(f"Prometido para eleição de líder (modo bootstrap) com proposta {proposal_number} do proposer {proposer_id}")
                    
                    # Atualizar o maior número prometido
                    self.highest_promised_number = proposal_number
                    
                    return jsonify({
                        "status": "promise",
                        "accepted_proposal_number": self.accepted_proposal_number,
                        "accepted_value": self.accepted_value
                    }), 200
                
                self.logger.info(f"Rejeitado proposta {proposal_number} do proposer {proposer_id} (prometido: {self.highest_promised_number})")
                return jsonify({
                    "status": "rejected",
                    "message": f"Already promised to higher proposal number: {self.highest_promised_number}"
                }), 200
    
    def _handle_accept(self, data):
        """
        Manipula requisições accept dos proposers.
        
        Args:
            data (dict): Dados do accept
        
        Returns:
            Response: Resposta HTTP
        """
        proposer_id = data.get('proposer_id')
        proposal_number = data.get('proposal_number')
        value = data.get('value')
        is_leader_election = data.get('is_leader_election', False)
        client_id = data.get('client_id')
        
        if not all([proposer_id, proposal_number, value]):
            return jsonify({"error": "Missing required information"}), 400
        
        with self.lock:
            # Verificar se o número da proposta é maior ou igual ao prometido
            if proposal_number >= self.highest_promised_number:
                self.accepted_proposal_number = proposal_number
                self.accepted_value = value
                
                if is_leader_election:
                    self.logger.info(f"Aceitou proposta de eleição {proposal_number} com valor: {value}")
                else:
                    self.logger.info(f"Aceitou proposta normal {proposal_number} com valor: {value}")
                
                # Atualizar metadata no Gossip
                self.gossip.update_local_metadata({
                    "accepted_proposal_number": proposal_number,
                    "accepted_value": value
                })
                
                # Se for eleição de líder, atualizar informação no Gossip
                if is_leader_election and value.startswith("leader:"):
                    leader_id = int(value.split(":")[1])
                    self.gossip.set_leader(leader_id)
                    self.logger.info(f"Atualizando líder para {leader_id}")
                
                # Notificar learners
                threading.Thread(target=self._notify_learners, 
                                args=(proposal_number, value, client_id, is_leader_election)).start()
                
                return jsonify({"status": "accepted"}), 200
            else:
                self.logger.info(f"Rejeitou proposta {proposal_number} (prometido: {self.highest_promised_number})")
                return jsonify({
                    "status": "rejected",
                    "message": f"Already promised to higher proposal number: {self.highest_promised_number}"
                }), 200
    
    def _notify_learners(self, proposal_number, value, client_id, is_leader_election):
        """
        Notificar learners sobre valor aceito
        
        Args:
            proposal_number (int): Número da proposta
            value (str): Valor aceito
            client_id (int): ID do cliente
            is_leader_election (bool): Se esta proposta é para eleição de líder
        """
        self.logger.info(f"Notificando learners sobre proposta {proposal_number}")
        
        # Obter learners via Gossip
        learners = self.gossip.get_nodes_by_role('learner')
        
        if not learners:
            self.logger.warning("Nenhum learner conhecido para notificar")
            return
        
        self.logger.info(f"Notificando {len(learners)} learners")
        
        # Implementar retry com backoff para notificações
        max_retries = 3
        base_timeout = 1.0
        
        for learner_id, learner in learners.items():
            for retry in range(max_retries):
                try:
                    learner_url = f"http://{learner['address']}:{learner['port']}/learn"
                    data = {
                        "acceptor_id": self.node_id,
                        "proposal_number": proposal_number,
                        "value": value,
                        "client_id": client_id,
                        "is_leader_election": is_leader_election
                    }
                    
                    # Timeout adaptativo com backoff exponencial
                    timeout = base_timeout * (2 ** retry)
                    
                    response = requests.post(learner_url, json=data, timeout=timeout)
                    
                    if response.status_code == 200:
                        self.logger.debug(f"Notificação enviada com sucesso para learner {learner_id}")
                        break  # Sucesso, sair do loop de retry
                    else:
                        self.logger.warning(f"Erro ao notificar learner {learner_id}: {response.text}")
                except Exception as e:
                    self.logger.error(f"Erro ao notificar learner {learner_id} (tentativa {retry+1}/{max_retries}): {e}")
                    
                    # Se não for a última tentativa, esperar antes de tentar novamente
                    if retry < max_retries - 1:
                        time.sleep(base_timeout * (2 ** retry) * 0.5)  # Backoff com valor reduzido
    
    def _handle_view_logs(self):
        """Manipulador para a rota view-logs"""
        learners = self.gossip.get_nodes_by_role('learner')
        
        return jsonify({
            "id": self.node_id,
            "role": self.node_role,
            "highest_promised_number": self.highest_promised_number,
            "accepted_proposal": {
                "number": self.accepted_proposal_number,
                "value": self.accepted_value
            },
            "learners_count": len(learners),
            "known_nodes_count": len(self.gossip.get_all_nodes()),
            "current_leader": self.gossip.get_leader()
        }), 200

# Para uso como aplicação independente
if __name__ == '__main__':
    acceptor = Acceptor()
    acceptor.start()