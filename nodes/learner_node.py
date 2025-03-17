import json
import time
import threading
import logging
import uuid
import random
import requests
from flask import request, jsonify
from collections import defaultdict, OrderedDict

from base_node import BaseNode

class Learner(BaseNode):
    """
    Implementação do nó Learner no algoritmo Paxos.
    Responsável por aprender e armazenar os valores que atingiram consenso,
    bem como notificar os clientes sobre esses valores.
    """
    
    def __init__(self, app=None):
        """
        Inicializa o nó Learner.
        """
        super().__init__(app)
        
        # Estruturas de dados para rastreamento de propostas
        self.learned_values = []  # Valores aprendidos em ordem
        self.proposal_counts = defaultdict(lambda: defaultdict(int))  # {proposal_number: {value: count}}
        self.acceptor_proposals = defaultdict(dict)  # {acceptor_id: {proposal_number: value}}
        
        # Estado compartilhado entre todos os nós
        self.shared_data = []  # Lista de valores em ordem de aprendizado
        
        # Cache para otimização
        self.learned_proposal_numbers = set()  # Conjunto para rápida verificação de proposals já aprendidas
        
        # Estado do líder
        self.current_leader = None
        
        # Métricas
        self.metrics = {
            "total_learned": 0,
            "values_by_type": defaultdict(int),
            "client_notifications": 0,
            "batch_notifications_received": 0,
            "single_notifications_received": 0
        }
        
        # Mapa de TIDs para evitar processamento duplicado
        self.processed_tids = set()
        self.max_processed_tids = 10000  # Limitar tamanho para evitar crescimento ilimitado
        
        self.logger.info(f"Learner inicializado com ID {self.node_id}")
    
    def _get_default_port(self):
        """Porta padrão para learners"""
        return 5000
    
    def _register_routes(self):
        """Registra as rotas específicas do learner"""
        @self.app.route('/learn', methods=['POST'])
        def learn():
            """Recebe notificação de valor aceito de um acceptor"""
            return self._handle_learn(request.json)
        
        @self.app.route('/get-values', methods=['GET'])
        def get_values():
            """Obtém valores aprendidos"""
            return self._handle_get_values()
        
        @self.app.route('/status', methods=['GET'])
        def status():
            """Retorna o status atual do learner"""
            return self._handle_status()
    
    def _handle_learn(self, data):
        """
        Processa notificações de valores aceitos enviados pelos acceptors.
        Suporta tanto notificações individuais quanto em lote.
        
        Args:
            data (dict): Dados da notificação
                - Um único objeto de notificação ou
                - Uma lista de notificações em 'notifications'
        
        Returns:
            Response: Resposta HTTP
        """
        # Verificar se é uma notificação em lote
        notifications = data.get('notifications')
        if notifications and isinstance(notifications, list):
            self.logger.info(f"Recebido lote com {len(notifications)} notificações")
            self.metrics["batch_notifications_received"] += 1
            
            results = []
            for notification in notifications:
                result = self._process_single_notification(notification)
                results.append(result)
            
            return jsonify({
                "status": "acknowledged",
                "processed": len(results),
                "learned": sum(1 for r in results if r.get("learned", False))
            }), 200
        else:
            # Notificação individual
            self.metrics["single_notifications_received"] += 1
            result = self._process_single_notification(data)
            
            return jsonify({
                "status": "acknowledged",
                "learned": result.get("learned", False)
            }), 200
    
    def _process_single_notification(self, data):
        """
        Processa uma única notificação de um acceptor.
        
        Args:
            data (dict): Dados da notificação
                - acceptor_id: ID do acceptor
                - proposal_number: Número da proposta
                - value: Valor aceito
                - tid: Transaction ID
                - is_leader_election: Se é eleição de líder
                - client_id: ID do cliente (opcional)
        
        Returns:
            dict: Resultado do processamento
        """
        acceptor_id = data.get('acceptor_id')
        proposal_number = data.get('proposal_number')
        value = data.get('value')
        tid = data.get('tid')
        is_leader_election = data.get('is_leader_election', False)
        client_id = data.get('client_id')
        
        if not all([acceptor_id, proposal_number, value, tid]):
            self.logger.warning(f"Notificação incompleta recebida: {data}")
            return {"learned": False, "error": "Missing required information"}
        
        # Verificar se já processamos este TID para evitar duplicação
        if tid in self.processed_tids:
            self.logger.debug(f"TID {tid} já processado, ignorando")
            return {"learned": False, "already_processed": True}
        
        # Adicionar TID ao conjunto de processados
        self.processed_tids.add(tid)
        
        # Limitar tamanho do conjunto de TIDs processados
        if len(self.processed_tids) > self.max_processed_tids:
            # Remover os mais antigos (estima-se que os primeiros sejam os mais antigos)
            self.processed_tids = set(list(self.processed_tids)[len(self.processed_tids) // 2:])
        
        with self.lock:
            # Registrar a proposta deste acceptor
            self.acceptor_proposals[acceptor_id][proposal_number] = value
            
            # Incrementar contador para esta proposta e valor
            self.proposal_counts[proposal_number][value] += 1
            
            # Obter contagem total de acceptors
            acceptors = self.gossip.get_nodes_by_role('acceptor')
            acceptor_count = len(acceptors)
            
            # Calcular tamanho do quórum (maioria)
            quorum_size = acceptor_count // 2 + 1
            
            # Verificar se este valor atingiu quórum para esta proposta
            value_count = self.proposal_counts[proposal_number][value]
            has_quorum = value_count >= quorum_size
            
            self.logger.info(f"Acceptor {acceptor_id} enviou valor: {value} para proposta {proposal_number}. Contagem: {value_count}/{quorum_size}")
            
            if has_quorum and proposal_number not in self.learned_proposal_numbers:
                # Marcar proposta como aprendida
                self.learned_proposal_numbers.add(proposal_number)
                
                # Se for eleição de líder, atualizar informação no gossip
                if is_leader_election and value.startswith("leader:"):
                    leader_id = int(value.split(":")[1])
                    self.current_leader = leader_id
                    self.gossip.set_leader(leader_id)
                    self.logger.info(f"Líder atualizado para {leader_id}")
                    
                    # Adicionar aos valores aprendidos
                    value_type = "leader_election"
                    self.metrics["values_by_type"][value_type] += 1
                    
                    learned_entry = {
                        "proposal_number": proposal_number,
                        "value": value,
                        "timestamp": time.time(),
                        "type": value_type,
                        "acceptor_count": value_count,
                        "quorum_size": quorum_size
                    }
                    self.learned_values.append(learned_entry)
                    
                else:
                    # Valor normal, adicionar aos dados compartilhados
                    self.shared_data.append(value)
                    
                    # Adicionar aos valores aprendidos
                    value_type = "normal"
                    self.metrics["values_by_type"][value_type] += 1
                    
                    learned_entry = {
                        "proposal_number": proposal_number,
                        "value": value,
                        "timestamp": time.time(),
                        "type": value_type,
                        "acceptor_count": value_count,
                        "quorum_size": quorum_size
                    }
                    self.learned_values.append(learned_entry)
                    
                    # Limitar o tamanho da lista de valores aprendidos
                    if len(self.learned_values) > 1000:
                        self.learned_values = self.learned_values[-1000:]
                    
                    # Atualizar contagem total
                    self.metrics["total_learned"] += 1
                    
                    # Atualizar metadata no gossip
                    self.gossip.update_local_metadata({
                        "last_learned_proposal": proposal_number,
                        "last_learned_value": value,
                        "learned_values_count": len(self.learned_values)
                    })
                    
                    self.logger.info(f"Aprendido valor: {value} da proposta {proposal_number} (quórum: {value_count}/{quorum_size})")
                    
                    # Notificar cliente se especificado
                    if client_id:
                        threading.Thread(
                            target=self._notify_client,
                            args=(client_id, value, proposal_number)
                        ).start()
                
                return {"learned": True, "value": value, "proposal_number": proposal_number}
            else:
                # Ainda não atingiu quórum ou já foi aprendido
                already_learned = proposal_number in self.learned_proposal_numbers
                if already_learned:
                    self.logger.debug(f"Proposta {proposal_number} já aprendida anteriormente")
                    
                return {"learned": False, "already_learned": already_learned}
    
    def _handle_get_values(self):
        """
        Responde a solicitações para obter valores aprendidos.
        
        Returns:
            Response: Resposta HTTP com os valores
        """
        # Opcional: adicionar parâmetros como limit, offset, etc.
        limit = request.args.get('limit', default=0, type=int)
        
        with self.lock:
            if limit > 0:
                values = self.shared_data[-limit:]
            else:
                values = self.shared_data
            
            return jsonify({
                "values": values,
                "total_count": len(self.shared_data),
                "returned_count": len(values)
            }), 200
    
    def _handle_status(self):
        """
        Retorna o status atual do learner.
        
        Returns:
            Response: Resposta HTTP com informações de status
        """
        clients = self.gossip.get_nodes_by_role('client')
        acceptors = self.gossip.get_nodes_by_role('acceptor')
        
        with self.lock:
            # Preparar metrics para serialização JSON
            json_metrics = dict(self.metrics)
            json_metrics["values_by_type"] = dict(json_metrics["values_by_type"])
            
            recent_values = self.learned_values[-10:] if self.learned_values else []
            
            return jsonify({
                "id": self.node_id,
                "role": self.node_role,
                "current_leader": self.current_leader,
                "learned_values_count": len(self.learned_values),
                "recent_learned_values": recent_values,
                "shared_data_count": len(self.shared_data),
                "recent_shared_data": self.shared_data[-10:] if self.shared_data else [],
                "clients_count": len(clients),
                "acceptors_count": len(acceptors),
                "known_nodes_count": len(self.gossip.get_all_nodes()),
                "metrics": json_metrics
            }), 200
    
    def _notify_client(self, client_id, value, proposal_number):
        """
        Notifica um cliente sobre um valor aprendido.
        
        Args:
            client_id (int): ID do cliente
            value (str): Valor aprendido
            proposal_number (int): Número da proposta
        """
        self.logger.info(f"Notificando cliente {client_id} sobre valor: {value}")
        
        # Obter clientes via gossip
        clients = self.gossip.get_nodes_by_role('client')
        
        # Encontrar o cliente específico
        client = None
        for cid, c in clients.items():
            if str(c['id']) == str(client_id):
                client = c
                break
        
        if client:
            # Implementar retry com backoff exponencial
            max_retries = 3
            base_timeout = 1.0
            
            for retry in range(max_retries):
                try:
                    # Timeout adaptativo com jitter para evitar sincronização
                    timeout = base_timeout * (2 ** retry) + random.uniform(0, 0.3)
                    
                    client_url = f"http://{client['address']}:{client['port']}/notify"
                    notification_data = {
                        "learner_id": self.node_id,
                        "proposal_number": proposal_number,
                        "value": value,
                        "learned_at": time.strftime("%Y-%m-%d %H:%M:%S")
                    }
                    
                    response = requests.post(client_url, json=notification_data, timeout=timeout)
                    
                    if response.status_code == 200:
                        self.logger.info(f"Cliente {client_id} notificado com sucesso sobre valor: {value}")
                        self.metrics["client_notifications"] += 1
                        break  # Sucesso, sair do loop
                    else:
                        self.logger.warning(f"Erro ao notificar cliente {client_id}: {response.status_code} - {response.text}")
                except Exception as e:
                    self.logger.error(f"Erro ao notificar cliente {client_id} (tentativa {retry+1}/{max_retries}): {e}")
                    
                    # Se não for a última tentativa, aguardar antes de tentar novamente
                    if retry < max_retries - 1:
                        time.sleep(base_timeout * (2 ** retry) * 0.5)
        else:
            self.logger.warning(f"Cliente {client_id} não encontrado para notificação")
    
    def _handle_view_logs(self):
        """
        Manipulador para a rota view-logs (para debugging).
        """
        clients = self.gossip.get_nodes_by_role('client')
        acceptors = self.gossip.get_nodes_by_role('acceptor')
        
        with self.lock:
            # Preparar metrics para serialização JSON
            json_metrics = dict(self.metrics)
            json_metrics["values_by_type"] = dict(json_metrics["values_by_type"])
            
            return jsonify({
                "id": self.node_id,
                "role": self.node_role,
                "learned_values_count": len(self.learned_values),
                "recent_learned_values": self.learned_values[-10:] if self.learned_values else [],
                "shared_data": self.shared_data if len(self.shared_data) <= 20 else self.shared_data[-20:],
                "clients_count": len(clients),
                "acceptors_count": len(acceptors),
                "known_nodes_count": len(self.gossip.get_all_nodes()),
                "current_leader": self.gossip.get_leader(),
                "metrics": json_metrics
            }), 200

# Para uso como aplicação independente
if __name__ == '__main__':
    learner = Learner()
    learner.start()