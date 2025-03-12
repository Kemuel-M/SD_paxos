import json
import time
import threading
import logging
import random
import requests
from flask import request, jsonify

from base_node import BaseNode

class Client(BaseNode):
    """
    Implementação do nó Cliente no algoritmo Paxos.
    Responsável por enviar requisições ao sistema e receber respostas.
    """
    
    def __init__(self, app=None):
        """
        Inicializa o nó Cliente.
        """
        super().__init__(app)
        
        # Estado específico do cliente
        self.responses = []
    
    def _get_default_port(self):
        """Porta padrão para clientes"""
        return 6000
    
    def _register_routes(self):
        """Registrar rotas específicas do cliente"""
        @self.app.route('/send', methods=['POST'])
        def send():
            """Enviar valor para o sistema Paxos"""
            return self._handle_send(request.json)
        
        @self.app.route('/notify', methods=['POST'])
        def notify():
            """Receber notificação de learner sobre valor aprendido"""
            return self._handle_notify(request.json)
        
        @self.app.route('/read', methods=['GET'])
        def read():
            """Ler valores aprendidos"""
            return self._handle_read()
        
        @self.app.route('/get-responses', methods=['GET'])
        def get_responses():
            """Obter respostas recebidas"""
            with self.lock:
                return jsonify({"responses": self.responses}), 200
    
    def _handle_send(self, data):
        """
        Manipula requisições para enviar valores ao sistema.
        
        Args:
            data (dict): Dados da requisição
        
        Returns:
            Response: Resposta HTTP
        """
        value = data.get('value')
        
        if not value:
            return jsonify({"error": "Value required"}), 400
        
        # Obter proposers via Gossip
        proposers = self.gossip.get_nodes_by_role('proposer')
        
        if not proposers:
            return jsonify({"error": "No proposers available"}), 503
        
        # Obter líder atual
        leader_id = self.gossip.get_leader()
        
        # Enviar para o líder, se conhecido, ou para um proposer aleatório
        target_proposer = None
        if leader_id and str(leader_id) in proposers:
            target_proposer = proposers[str(leader_id)]
            self.logger.info(f"Usando líder conhecido: {leader_id}")
        else:
            # Escolher um proposer aleatório
            proposer_id = random.choice(list(proposers.keys()))
            target_proposer = proposers[proposer_id]
            self.logger.info(f"Escolhendo proposer aleatório: {proposer_id}")
        
        try:
            proposer_url = f"http://{target_proposer['address']}:{target_proposer['port']}/propose"
            send_data = {
                "value": value,
                "client_id": self.node_id
            }
            
            response = requests.post(proposer_url, json=send_data, timeout=5)
            
            if response.status_code == 200:
                self.logger.info(f"Valor '{value}' enviado para proposer {target_proposer['id']}")
                return jsonify({"status": "value sent", "proposer_id": target_proposer['id']}), 200
            elif response.status_code == 403:
                # Não é o líder, tente o líder sugerido
                result = response.json()
                new_leader = result.get("current_leader")
                
                if new_leader and str(new_leader) in proposers:
                    new_target = proposers[str(new_leader)]
                    proposer_url = f"http://{new_target['address']}:{new_target['port']}/propose"
                    
                    response = requests.post(proposer_url, json=send_data, timeout=5)
                    
                    if response.status_code == 200:
                        self.logger.info(f"Valor '{value}' enviado para líder {new_target['id']}")
                        return jsonify({"status": "value sent", "proposer_id": new_target['id']}), 200
                    else:
                        return jsonify({"error": f"Error sending to leader: {response.text}"}), 500
                else:
                    return jsonify({"error": "Leader not available"}), 503
            else:
                return jsonify({"error": f"Error sending to proposer: {response.text}"}), 500
        except Exception as e:
            self.logger.error(f"Erro ao enviar para proposer: {e}")
            return jsonify({"error": str(e)}), 500
    
    def _handle_notify(self, data):
        """
        Manipula notificações de valores aprendidos dos learners.
        
        Args:
            data (dict): Dados da notificação
        
        Returns:
            Response: Resposta HTTP
        """
        learner_id = data.get('learner_id')
        proposal_number = data.get('proposal_number')
        value = data.get('value')
        learned_at = data.get('learned_at')
        
        if not all([learner_id, proposal_number, value]):
            return jsonify({"error": "Missing required information"}), 400
        
        with self.lock:
            self.responses.append({
                "learner_id": learner_id,
                "proposal_number": proposal_number,
                "value": value,
                "learned_at": learned_at,
                "received_at": time.strftime("%Y-%m-%d %H:%M:%S")
            })
        
        self.logger.info(f"Notificação recebida do learner {learner_id}: valor '{value}' foi aprendido")
        return jsonify({"status": "acknowledged"}), 200
    
    def _handle_read(self):
        """
        Manipula requisições para ler valores do sistema.
        
        Returns:
            Response: Resposta HTTP
        """
        # Encontrar learners via Gossip
        learners = self.gossip.get_nodes_by_role('learner')
        
        if not learners:
            return jsonify({"error": "No learners available"}), 503
        
        # Escolher um learner aleatório
        learner_id = random.choice(list(learners.keys()))
        learner = learners[learner_id]
        
        try:
            learner_url = f"http://{learner['address']}:{learner['port']}/get-values"
            response = requests.get(learner_url, timeout=5)
            
            if response.status_code == 200:
                values = response.json().get("values", [])
                self.logger.info(f"Leitura concluída: {len(values)} valores obtidos do learner {learner_id}")
                return jsonify({"values": values}), 200
            else:
                return jsonify({"error": f"Error reading from learner: {response.text}"}), 500
        except Exception as e:
            self.logger.error(f"Erro ao ler do learner: {e}")
            return jsonify({"error": str(e)}), 500
    
    def _handle_view_logs(self):
        """Manipulador para a rota view-logs"""
        proposers = self.gossip.get_nodes_by_role('proposer')
        
        return jsonify({
            "id": self.node_id,
            "role": self.node_role,
            "proposers_count": len(proposers),
            "responses_count": len(self.responses),
            "recent_responses": self.responses[-10:] if self.responses else [],
            "known_nodes_count": len(self.gossip.get_all_nodes()),
            "current_leader": self.gossip.get_leader()
        }), 200

# Para uso como aplicação independente
if __name__ == '__main__':
    client = Client()
    client.start()