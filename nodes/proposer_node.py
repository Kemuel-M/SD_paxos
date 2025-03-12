import json
import time
import threading
import logging
import requests
from flask import request, jsonify

from base_node import BaseNode

class Proposer(BaseNode):
    """
    Implementação do nó Proposer no algoritmo Paxos.
    Responsável por propor valores e coordenar o consenso.
    """
    
    def __init__(self, app=None):
        """
        Inicializa o nó Proposer.
        """
        super().__init__(app)
        
        # Estado específico do proposer
        self.proposal_counter = 0
        self.in_election = False
        self.election_timeout = 5  # segundos
        
        # Valores de proposta atual
        self.current_proposal_number = 0
        self.proposed_value = None
        self.proposal_accepted_count = 0
        self.waiting_for_acceptor_response = False
    
    def _get_default_port(self):
        """Porta padrão para proposers"""
        return 3000
    
    def _register_routes(self):
        """Registrar rotas específicas do proposer"""
        @self.app.route('/propose', methods=['POST'])
        def propose():
            """Receber proposta de um cliente"""
            return self._handle_propose(request.json)
    
    def _start_threads(self):
        """Iniciar threads específicas do proposer"""
        # Thread de verificação de líder
        threading.Thread(target=self._check_leader, daemon=True).start()
        
        # Thread de heartbeat de líder
        threading.Thread(target=self._leader_heartbeat, daemon=True).start()
    
    def _handle_propose(self, data):
        """
        Manipula requisições de proposta de clientes.
        
        Args:
            data (dict): Dados da proposta do cliente
        
        Returns:
            Response: Resposta HTTP
        """
        # Verificar se este nó é o líder
        current_leader = self.gossip.get_leader()
        is_leader = current_leader is not None and int(current_leader) == self.node_id
        
        if not is_leader:
            # Redirecionar para o líder atual, se conhecido
            if current_leader:
                try:
                    leader_info = self.gossip.get_node_info(str(current_leader))
                    if leader_info:
                        leader_url = f"http://{leader_info['address']}:{leader_info['port']}/propose"
                        try:
                            response = requests.post(leader_url, json=data, timeout=5)
                            return response.content, response.status_code
                        except Exception as e:
                            self.logger.error(f"Erro ao redirecionar para líder: {e}")
                except Exception as e:
                    self.logger.error(f"Erro ao obter informações do líder: {e}")
            
            return jsonify({"error": "Not the leader", "current_leader": current_leader}), 403
        
        value = data.get('value')
        client_id = data.get('client_id')
        
        if not value:
            return jsonify({"error": "Value required"}), 400
        
        with self.lock:
            if self.waiting_for_acceptor_response:
                return jsonify({"error": "Already processing a proposal"}), 429
            
            self.waiting_for_acceptor_response = True
            self.proposed_value = value
            self.proposal_counter += 1
            self.current_proposal_number = self.proposal_counter * 100 + self.node_id
            self.proposal_accepted_count = 0
        
        self.logger.info(f"Recebida proposta do cliente {client_id}: {value}")
        
        # Enviar prepare para todos os acceptors
        try:
            acceptors = self.gossip.get_nodes_by_role('acceptor')
            quorum_size = len(acceptors) // 2 + 1
            
            if quorum_size == 0:
                with self.lock:
                    self.waiting_for_acceptor_response = False
                return jsonify({"error": "No acceptors available"}), 503
            
            self.logger.info(f"Enviando prepare para {len(acceptors)} acceptors")
            
            for acceptor_id, acceptor in acceptors.items():
                try:
                    acceptor_url = f"http://{acceptor['address']}:{acceptor['port']}/prepare"
                    prepare_data = {
                        "proposer_id": self.node_id,
                        "proposal_number": self.current_proposal_number,
                        "is_leader_election": False
                    }
                    
                    threading.Thread(target=self._send_client_prepare, args=(
                        acceptor_url, prepare_data, quorum_size, value, client_id)).start()
                except Exception as e:
                    self.logger.error(f"Erro ao enviar prepare para acceptor {acceptor_id}: {e}")
            
            return jsonify({"status": "proposal received", "proposal_number": self.current_proposal_number}), 200
        except Exception as e:
            self.logger.error(f"Erro ao processar proposta: {e}")
            with self.lock:
                self.waiting_for_acceptor_response = False
            return jsonify({"error": str(e)}), 500
    
    def _check_leader(self):
        """Verificar se há um líder ativo e iniciar eleição se necessário"""
        while True:
            try:
                current_leader = self.gossip.get_leader()
                
                with self.lock:
                    # Se não houver líder
                    if current_leader is None:
                        if not self.in_election:
                            self.logger.info("Sem líder detectado, iniciando eleição")
                            self._start_election()
                    # Se este nó for o líder
                    elif int(current_leader) == self.node_id:
                        self.gossip.update_local_metadata({"is_leader": True})
                        self.logger.info("Este nó é o líder!")
                    # Se outro nó for o líder
                    else:
                        is_leader = self.gossip.get_node_info(str(self.node_id))
                        if is_leader and is_leader.get('metadata', {}).get('is_leader', False):
                            self.gossip.update_local_metadata({"is_leader": False})
            except Exception as e:
                self.logger.error(f"Erro ao verificar líder: {e}")
            
            time.sleep(2)  # Verificar a cada 2 segundos
    
    def _leader_heartbeat(self):
        """Enviar heartbeat como líder para os outros nós"""
        while True:
            # Verificar se este nó é o líder
            is_leader = False
            current_leader = self.gossip.get_leader()
            
            if current_leader is not None and int(current_leader) == self.node_id:
                is_leader = True
                self.logger.debug("Enviando heartbeat de líder via Gossip")
                # O próprio mecanismo de Gossip propaga o status de líder
                self.gossip.update_local_metadata({
                    "is_leader": True,
                    "last_heartbeat": time.time()
                })
            
            time.sleep(3)  # Enviar a cada 3 segundos
    
    def _start_election(self):
        """Iniciar uma eleição para líder"""
        with self.lock:
            if self.in_election:
                return
            
            self.in_election = True
            # Gerar número de proposta: timestamp * 100 + ID para garantir unicidade
            proposal_counter = int(time.time()) % 10000
            self.current_proposal_number = proposal_counter * 100 + self.node_id
            self.proposal_accepted_count = 0
        
        self.logger.info(f"Iniciando eleição com proposta número {self.current_proposal_number}")
        
        # Enviar mensagem prepare para todos os acceptors
        try:
            acceptors = self.gossip.get_nodes_by_role('acceptor')
            quorum_size = len(acceptors) // 2 + 1
            
            if quorum_size == 0:
                self.logger.warning("Nenhum acceptor disponível para eleição")
                with self.lock:
                    self.in_election = False
                return
            
            self.logger.info(f"Enviando prepare para {len(acceptors)} acceptors (quorum: {quorum_size})")
            
            for acceptor_id, acceptor in acceptors.items():
                try:
                    acceptor_url = f"http://{acceptor['address']}:{acceptor['port']}/prepare"
                    data = {
                        "proposer_id": self.node_id,
                        "proposal_number": self.current_proposal_number,
                        "is_leader_election": True
                    }
                    
                    threading.Thread(target=self._send_prepare, args=(acceptor_url, data, quorum_size)).start()
                except Exception as e:
                    self.logger.error(f"Erro ao enviar prepare para acceptor {acceptor_id}: {e}")
        except Exception as e:
            self.logger.error(f"Erro ao iniciar eleição: {e}")
            with self.lock:
                self.in_election = False
    
    def _send_prepare(self, url, data, quorum_size):
        """
        Enviar mensagem prepare para um acceptor
        
        Args:
            url (str): URL do acceptor
            data (dict): Dados para enviar
            quorum_size (int): Tamanho do quórum necessário
        """
        try:
            response = requests.post(url, json=data, timeout=5)
            
            if response.status_code == 200:
                result = response.json()
                if result.get("status") == "promise":
                    with self.lock:
                        self.proposal_accepted_count += 1
                        self.logger.info(f"Recebido promise: {self.proposal_accepted_count}/{quorum_size}")
                        
                        # Se atingir o quórum, torna-se líder
                        if self.proposal_accepted_count >= quorum_size and self.in_election:
                            self.in_election = False
                            self.logger.info("Quórum atingido! Tornando-se líder")
                            
                            # Atualizar informação de líder no Gossip
                            self.gossip.set_leader(self.node_id)
                            
                            # Enviar mensagem accept para todos os acceptors
                            try:
                                acceptors = self.gossip.get_nodes_by_role('acceptor')
                                for acceptor_id, acceptor in acceptors.items():
                                    acceptor_url = f"http://{acceptor['address']}:{acceptor['port']}/accept"
                                    accept_data = {
                                        "proposer_id": self.node_id,
                                        "proposal_number": self.current_proposal_number,
                                        "is_leader_election": True,
                                        "value": f"leader:{self.node_id}"
                                    }
                                    
                                    try:
                                        requests.post(acceptor_url, json=accept_data, timeout=5)
                                    except Exception as e:
                                        self.logger.error(f"Erro ao enviar accept para acceptor {acceptor_id}: {e}")
                            except Exception as e:
                                self.logger.error(f"Erro ao enviar accepts após eleição: {e}")
                else:
                    self.logger.info(f"Acceptor rejeitou proposta: {result.get('message')}")
            else:
                self.logger.error(f"Erro ao enviar prepare: {response.text}")
        except Exception as e:
            self.logger.error(f"Erro ao enviar prepare: {e}")
    
    def _send_client_prepare(self, acceptor_url, prepare_data, quorum_size, value, client_id):
        """
        Enviar mensagem prepare para um acceptor (para proposta de cliente)
        
        Args:
            acceptor_url (str): URL do acceptor
            prepare_data (dict): Dados do prepare
            quorum_size (int): Tamanho do quórum necessário
            value (str): Valor proposto
            client_id (int): ID do cliente
        """
        try:
            response = requests.post(acceptor_url, json=prepare_data, timeout=5)
            
            if response.status_code == 200:
                result = response.json()
                if result.get("status") == "promise":
                    with self.lock:
                        self.proposal_accepted_count += 1
                        self.logger.info(f"Recebido promise para proposta do cliente: {self.proposal_accepted_count}/{quorum_size}")
                        
                        # Se atingir o quórum, enviar accept
                        if self.proposal_accepted_count >= quorum_size and self.waiting_for_acceptor_response:
                            self.logger.info("Quórum atingido para proposta do cliente! Enviando accepts")
                            
                            # Enviar mensagem accept para todos os acceptors
                            try:
                                acceptors = self.gossip.get_nodes_by_role('acceptor')
                                for acceptor_id, acceptor in acceptors.items():
                                    acceptor_url = f"http://{acceptor['address']}:{acceptor['port']}/accept"
                                    accept_data = {
                                        "proposer_id": self.node_id,
                                        "proposal_number": self.current_proposal_number,
                                        "is_leader_election": False,
                                        "value": value,
                                        "client_id": client_id
                                    }
                                    
                                    try:
                                        requests.post(acceptor_url, json=accept_data, timeout=5)
                                    except Exception as e:
                                        self.logger.error(f"Erro ao enviar accept para acceptor {acceptor_id}: {e}")
                                
                                # Reiniciar estado
                                self.waiting_for_acceptor_response = False
                            except Exception as e:
                                self.logger.error(f"Erro ao enviar accepts após quórum: {e}")
                                self.waiting_for_acceptor_response = False
                else:
                    self.logger.info(f"Acceptor rejeitou proposta do cliente: {result.get('message')}")
                    with self.lock:
                        # Se algum acceptor rejeitar, precisamos finalizar
                        if self.waiting_for_acceptor_response:
                            self.waiting_for_acceptor_response = False
            else:
                self.logger.error(f"Erro ao enviar prepare para proposta do cliente: {response.text}")
                with self.lock:
                    if self.waiting_for_acceptor_response:
                        self.waiting_for_acceptor_response = False
        except Exception as e:
            self.logger.error(f"Erro ao enviar prepare para proposta do cliente: {e}")
            with self.lock:
                if self.waiting_for_acceptor_response:
                    self.waiting_for_acceptor_response = False
    
    def _handle_view_logs(self):
        """Manipulador para a rota view-logs"""
        current_leader = self.gossip.get_leader()
        is_leader = current_leader is not None and int(current_leader) == self.node_id
        
        acceptors = self.gossip.get_nodes_by_role('acceptor')
        learners = self.gossip.get_nodes_by_role('learner')
        
        return jsonify({
            "id": self.node_id,
            "role": self.node_role,
            "is_leader": is_leader,
            "current_leader": current_leader,
            "in_election": self.in_election,
            "proposal_counter": self.proposal_counter,
            "acceptors_count": len(acceptors),
            "learners_count": len(learners),
            "known_nodes_count": len(self.gossip.get_all_nodes()),
            "current_proposal": {
                "number": self.current_proposal_number,
                "value": self.proposed_value,
                "accepted_count": self.proposal_accepted_count,
                "waiting_for_response": self.waiting_for_acceptor_response
            }
        }), 200

# Para uso como aplicação independente
if __name__ == '__main__':
    proposer = Proposer()
    proposer.start()