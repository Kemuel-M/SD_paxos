import json
import time
import threading
import logging
import requests
from flask import request, jsonify
from collections import defaultdict

from base_node import BaseNode

class Learner(BaseNode):
    """
    Implementação do nó Learner no algoritmo Paxos.
    Responsável por aprender os valores que alcançaram consenso.
    """
    
    def __init__(self, app=None):
        """
        Inicializa o nó Learner.
        """
        super().__init__(app)
        
        # Estado específico do learner
        self.learned_values = []
        self.proposal_counts = defaultdict(int)
        self.acceptor_responses = defaultdict(dict)
        
        # Estado compartilhado entre todos os nós (simulação)
        self.shared_data = []
    
    def _get_default_port(self):
        """Porta padrão para learners"""
        return 5000
    
    def _register_routes(self):
        """Registrar rotas específicas do learner"""
        @self.app.route('/learn', methods=['POST'])
        def learn():
            """Receber notificação de valor aceito de um acceptor"""
            return self._handle_learn(request.json)
        
        @self.app.route('/get-values', methods=['GET'])
        def get_values():
            """Obter valores aprendidos"""
            return jsonify({"values": self.shared_data}), 200
    
    def _handle_learn(self, data):
        """
        Manipula notificações de valores aceitos dos acceptors.
        
        Args:
            data (dict): Dados da notificação
        
        Returns:
            Response: Resposta HTTP
        """
        acceptor_id = data.get('acceptor_id')
        proposal_number = data.get('proposal_number')
        value = data.get('value')
        client_id = data.get('client_id')
        is_leader_election = data.get('is_leader_election', False)
        
        if not all([acceptor_id, proposal_number, value]):
            return jsonify({"error": "Missing required information"}), 400
        
        with self.lock:
            # Registrar resposta deste acceptor
            self.acceptor_responses[proposal_number][acceptor_id] = value
            
            # Verificar quórum (mais da metade dos acceptors concordam com o mesmo valor)
            acceptors = self.gossip.get_nodes_by_role('acceptor')
            quorum_size = len(acceptors) // 2 + 1
            
            # Contar quantos acceptors concordam com este valor
            value_count = sum(1 for v in self.acceptor_responses[proposal_number].values() if v == value)
            
            self.logger.info(f"Acceptor {acceptor_id} enviou valor: {value} para proposta {proposal_number}. Contagem: {value_count}/{quorum_size}")
            
            if value_count >= quorum_size:
                # Se for uma eleição de líder, atualizar informação no Gossip
                if is_leader_election and value.startswith("leader:"):
                    leader_id = int(value.split(":")[1])
                    self.gossip.set_leader(leader_id)
                    self.logger.info(f"Atualizando líder para {leader_id}")
                else:
                    # Adicionar aos valores aprendidos
                    self.learned_values.append({
                        "proposal_number": proposal_number, 
                        "value": value, 
                        "timestamp": time.time()
                    })
                    
                    # Atualizar dados compartilhados
                    self.shared_data.append(value)
                    
                    # Atualizar metadata no Gossip
                    self.gossip.update_local_metadata({
                        "last_learned_proposal": proposal_number,
                        "last_learned_value": value,
                        "learned_values_count": len(self.learned_values)
                    })
                    
                    self.logger.info(f"Aprendido valor: {value} da proposta {proposal_number}")
                    
                    # Notificar cliente
                    if client_id:
                        threading.Thread(target=self._notify_client, 
                                        args=(client_id, value, proposal_number)).start()
        
        return jsonify({"status": "acknowledged"}), 200
    
    def _notify_client(self, client_id, value, proposal_number):
        """
        Notificar cliente sobre valor aprendido
        
        Args:
            client_id (int): ID do cliente
            value (str): Valor aprendido
            proposal_number (int): Número da proposta
        """
        self.logger.info(f"Procurando cliente {client_id} para notificar")
        
        # Obter clientes via Gossip
        clients = self.gossip.get_nodes_by_role('client')
        
        client = None
        for cid, c in clients.items():
            if str(c['id']) == str(client_id):
                client = c
                break
        
        if client:
            try:
                client_url = f"http://{client['address']}:{client['port']}/notify"
                data = {
                    "learner_id": self.node_id,
                    "proposal_number": proposal_number,
                    "value": value,
                    "learned_at": time.strftime("%Y-%m-%d %H:%M:%S")
                }
                
                response = requests.post(client_url, json=data, timeout=5)
                if response.status_code != 200:
                    self.logger.warning(f"Erro ao notificar cliente {client_id}: {response.text}")
                else:
                    self.logger.info(f"Cliente {client_id} notificado sobre valor: {value}")
            except Exception as e:
                self.logger.error(f"Erro ao notificar cliente {client_id}: {e}")
        else:
            self.logger.warning(f"Cliente {client_id} não encontrado")
    
    def _handle_view_logs(self):
        """Manipulador para a rota view-logs"""
        clients = self.gossip.get_nodes_by_role('client')
        
        return jsonify({
            "id": self.node_id,
            "role": self.node_role,
            "learned_values_count": len(self.learned_values),
            "recent_learned_values": self.learned_values[-10:] if self.learned_values else [],
            "shared_data": self.shared_data,
            "clients_count": len(clients),
            "known_nodes_count": len(self.gossip.get_all_nodes()),
            "current_leader": self.gossip.get_leader()
        }), 200

# Para uso como aplicação independente
if __name__ == '__main__':
    learner = Learner()
    learner.start()