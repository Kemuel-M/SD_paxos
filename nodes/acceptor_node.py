import json
import time
import threading
import logging
import uuid
import random
import requests
from flask import request, jsonify
from collections import OrderedDict

from base_node import BaseNode

class Acceptor(BaseNode):
    """
    Implementação do nó Acceptor no algoritmo Paxos.
    Responsável por aceitar ou rejeitar propostas dos proposers,
    garantindo a consistência do consenso no sistema distribuído.
    """
    
    def __init__(self, app=None):
        """
        Inicializa o nó Acceptor com seu estado persistente.
        """
        super().__init__(app)
        
        # Estado persistente (deve ser salvo para recuperação após falhas)
        self.max_promised = 0        # Maior número de proposta prometido
        self.max_accepted = 0        # Maior número de proposta aceito
        self.accepted_value = None   # Valor associado ao max_accepted
        
        # Histórico de propostas (limitado aos últimos N)
        self.proposal_history = OrderedDict()
        self.max_history_size = 100  # Tamanho máximo do histórico
        
        # Estado volátil (reinicializado após falhas)
        self.last_heartbeat_time = 0
        self.current_leader_id = None
        self.proposer_heartbeats = {}
        
        # Cache para otimização de desempenho
        self.response_cache = {}
        self.cache_ttl = 60  # Tempo de vida do cache em segundos
        self.cache_cleanup_interval = 300  # Intervalo de limpeza do cache em segundos
        
        # Controle de monitoramento do líder
        self.leader_timeout = 10     # Segundos para considerar o líder como falho
        
        # Métricas e estatísticas
        self.metrics = {
            "promises_made": 0,
            "promises_rejected": 0,
            "values_accepted": 0,
            "accepts_rejected": 0,
            "learner_notifications": 0,
            "heartbeats_received": 0
        }
        
        # Parâmetros de comunicação
        self.notification_batch_size = 10  # Tamanho do lote para notificações
        self.pending_notifications = []    # Fila de notificações pendentes
        
        self.logger.info(f"Acceptor inicializado com ID {self.node_id}")
    
    def _get_default_port(self):
        """Porta padrão para acceptors"""
        return 4000
    
    def _register_routes(self):
        """Registra as rotas específicas do acceptor"""
        @self.app.route('/prepare', methods=['POST'])
        def prepare():
            """Receber mensagem PREPARE de um proposer"""
            return self._handle_prepare(request.json)
        
        @self.app.route('/accept', methods=['POST'])
        def accept():
            """Receber mensagem ACCEPT de um proposer"""
            return self._handle_accept(request.json)
        
        @self.app.route('/status', methods=['GET'])
        def status():
            """Retorna o status atual do acceptor"""
            return self._handle_status()
        
        @self.app.route('/heartbeat', methods=['POST'])
        def heartbeat():
            """Receber heartbeat do líder"""
            return self._handle_heartbeat(request.json)
    
    def _start_threads(self):
        """Inicia as threads específicas do acceptor"""
        # Thread para verificar o status do líder
        threading.Thread(target=self._check_leader_status, daemon=True).start()
        
        # Thread para envio em lote de notificações aos learners
        threading.Thread(target=self._notify_learners_batch, daemon=True).start()
        
        # Thread para limpeza periódica do cache
        threading.Thread(target=self._cleanup_cache, daemon=True).start()
    
    def _generate_tid(self):
        """
        Gera um Transaction ID (TID) único para cada operação.
        
        Returns:
            str: TID único no formato 'acceptor_id-timestamp-random'
        """
        timestamp = int(time.time() * 1000)
        random_part = random.randint(1000, 9999)
        return f"{self.node_id}-{timestamp}-{random_part}"
    
    def _handle_prepare(self, data):
        """
        Processa uma mensagem PREPARE de um proposer.
        
        Args:
            data (dict): Dados do PREPARE
                - proposer_id: ID do proposer
                - proposal_number: Número da proposta
                - is_leader_election: Se é uma eleição de líder
        
        Returns:
            Response: Resposta HTTP
        """
        proposer_id = data.get('proposer_id')
        proposal_number = data.get('proposal_number')
        is_leader_election = data.get('is_leader_election', False)
        
        if not all([proposer_id, proposal_number]):
            return jsonify({"error": "Missing required information"}), 400
        
        # Verificar se já processamos este prepare (cache)
        cache_key = f"prepare_{proposer_id}_{proposal_number}"
        if cache_key in self.response_cache:
            self.logger.debug(f"Usando resposta em cache para PREPARE {proposal_number}")
            return self.response_cache[cache_key]
        
        timestamp = time.time()
        tid = self._generate_tid()
        
        with self.lock:
            # Registrar no histórico
            self.proposal_history[tid] = {
                "type": "prepare",
                "proposal_number": proposal_number,
                "proposer_id": proposer_id,
                "timestamp": timestamp,
                "is_leader_election": is_leader_election,
                "result": None  # Será atualizado abaixo
            }
            
            # Se o histórico ficar muito grande, remover entradas antigas
            if len(self.proposal_history) > self.max_history_size:
                self.proposal_history.popitem(last=False)  # Remove o mais antigo (FIFO)
            
            # Fase 1 do Paxos: Comparar o número da proposta com o máximo prometido
            if proposal_number > self.max_promised:
                # Aceitar a proposta
                old_max_promised = self.max_promised
                self.max_promised = proposal_number
                
                # Registrar resultado
                self.proposal_history[tid]["result"] = "promised"
                self.metrics["promises_made"] += 1
                
                # Preparar resposta
                response = {
                    "status": "promise",
                    "acceptor_id": self.node_id,
                    "tid": tid,
                    "timestamp": timestamp,
                    "max_accepted": self.max_accepted,
                    "accepted_value": self.accepted_value
                }
                
                # Log baseado no tipo de proposta
                if is_leader_election:
                    self.logger.info(f"PROMISE enviado para eleição de líder com proposta {proposal_number} do proposer {proposer_id} (anterior: {old_max_promised})")
                else:
                    self.logger.info(f"PROMISE enviado para proposta normal {proposal_number} do proposer {proposer_id} (anterior: {old_max_promised})")
            else:
                # Rejeitar a proposta
                self.proposal_history[tid]["result"] = "rejected"
                self.metrics["promises_rejected"] += 1
                
                # Preparar resposta
                response = {
                    "status": "rejected",
                    "acceptor_id": self.node_id,
                    "tid": tid,
                    "timestamp": timestamp,
                    "message": f"Already promised to higher proposal number: {self.max_promised}"
                }
                
                # Log
                self.logger.info(f"PREPARE rejeitado: proposta {proposal_number} < máximo prometido {self.max_promised}")
        
        # Armazenar em cache
        http_response = jsonify(response), 200
        self.response_cache[cache_key] = http_response
        
        return http_response
    
    def _handle_accept(self, data):
        """
        Processa uma mensagem ACCEPT de um proposer.
        
        Args:
            data (dict): Dados do ACCEPT
                - proposer_id: ID do proposer
                - proposal_number: Número da proposta
                - value: Valor proposto
                - is_leader_election: Se é uma eleição de líder
                - client_id: ID do cliente (opcional)
        
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
        
        # Verificar se já processamos este accept (cache)
        cache_key = f"accept_{proposer_id}_{proposal_number}_{value}"
        if cache_key in self.response_cache:
            self.logger.debug(f"Usando resposta em cache para ACCEPT {proposal_number}")
            return self.response_cache[cache_key]
        
        timestamp = time.time()
        tid = self._generate_tid()
        
        with self.lock:
            # Registrar no histórico
            self.proposal_history[tid] = {
                "type": "accept",
                "proposal_number": proposal_number,
                "proposer_id": proposer_id,
                "value": value,
                "timestamp": timestamp,
                "is_leader_election": is_leader_election,
                "client_id": client_id,
                "result": None  # Será atualizado abaixo
            }
            
            # Se o histórico ficar muito grande, remover entradas antigas
            if len(self.proposal_history) > self.max_history_size:
                self.proposal_history.popitem(last=False)
            
            # Fase 2 do Paxos: Comparar o número da proposta com o máximo prometido
            if proposal_number >= self.max_promised:
                # Aceitar o valor
                old_max_accepted = self.max_accepted
                
                self.max_promised = max(self.max_promised, proposal_number)
                self.max_accepted = proposal_number
                self.accepted_value = value
                
                # Registrar resultado
                self.proposal_history[tid]["result"] = "accepted"
                self.metrics["values_accepted"] += 1
                
                # Preparar resposta
                response = {
                    "status": "accepted",
                    "acceptor_id": self.node_id,
                    "tid": tid,
                    "timestamp": timestamp
                }
                
                # Log baseado no tipo de proposta
                if is_leader_election:
                    self.logger.info(f"ACCEPTED: eleição de líder com proposta {proposal_number}, valor: {value}")
                    
                    # Se for eleição de líder, atualizar o líder no gossip
                    if value.startswith("leader:"):
                        leader_id = int(value.split(":")[1])
                        self.current_leader_id = leader_id
                        self.gossip.set_leader(leader_id)
                        self.logger.info(f"Líder atualizado para {leader_id}")
                else:
                    self.logger.info(f"ACCEPTED: proposta normal {proposal_number}, valor: {value} (anterior: {old_max_accepted})")
                
                # Adicionar à fila de notificações para learners
                notification = {
                    "acceptor_id": self.node_id,
                    "proposal_number": proposal_number,
                    "value": value,
                    "tid": tid,
                    "timestamp": timestamp,
                    "is_leader_election": is_leader_election,
                    "client_id": client_id
                }
                
                self.pending_notifications.append(notification)
                
                # Se temos muitas notificações pendentes ou é uma eleição, notificar imediatamente
                if len(self.pending_notifications) >= self.notification_batch_size or is_leader_election:
                    threading.Thread(target=self._notify_learners_now, daemon=True).start()
            else:
                # Rejeitar o valor
                self.proposal_history[tid]["result"] = "rejected"
                self.metrics["accepts_rejected"] += 1
                
                # Preparar resposta
                response = {
                    "status": "rejected",
                    "acceptor_id": self.node_id,
                    "tid": tid,
                    "timestamp": timestamp,
                    "message": f"Already promised to higher proposal number: {self.max_promised}"
                }
                
                # Log
                self.logger.info(f"ACCEPT rejeitado: proposta {proposal_number} < máximo prometido {self.max_promised}")
        
        # Armazenar em cache
        http_response = jsonify(response), 200
        self.response_cache[cache_key] = http_response
        
        return http_response
    
    def _handle_heartbeat(self, data):
        """
        Processa um heartbeat do líder.
        
        Args:
            data (dict): Dados do heartbeat
                - leader_id: ID do líder
                - timestamp: Timestamp do heartbeat
                - sequence_number: Número de sequência (opcional)
        
        Returns:
            Response: Resposta HTTP
        """
        leader_id = data.get('leader_id')
        timestamp = data.get('timestamp', time.time())
        sequence_number = data.get('sequence_number', 0)
        
        if leader_id is None:
            return jsonify({"error": "Missing leader_id"}), 400
        
        current_time = time.time()
        
        with self.lock:
            # Atualizar último heartbeat recebido
            self.last_heartbeat_time = current_time
            self.current_leader_id = leader_id
            
            # Atualizar o líder no gossip
            self.gossip.set_leader(leader_id)
            
            # Registrar heartbeat para este proposer
            self.proposer_heartbeats[str(leader_id)] = {
                "timestamp": current_time,
                "sequence_number": sequence_number
            }
            
            self.metrics["heartbeats_received"] += 1
        
        self.logger.debug(f"Heartbeat recebido do líder {leader_id} (seq: {sequence_number})")
        
        return jsonify({
            "status": "acknowledged",
            "acceptor_id": self.node_id,
            "received_at": current_time
        }), 200
    
    def _handle_status(self):
        """
        Retorna o status atual do acceptor.
        
        Returns:
            Response: Resposta HTTP com informações de status
        """
        with self.lock:
            # Obter algumas entradas recentes do histórico
            recent_history = list(self.proposal_history.values())[-10:] if self.proposal_history else []
            
            learners = self.gossip.get_nodes_by_role('learner')
            
            return jsonify({
                "id": self.node_id,
                "role": self.node_role,
                "current_leader": self.current_leader_id,
                "state": {
                    "max_promised": self.max_promised,
                    "max_accepted": self.max_accepted,
                    "accepted_value": self.accepted_value,
                    "last_heartbeat": self.last_heartbeat_time
                },
                "metrics": self.metrics,
                "recent_proposals": recent_history,
                "learners_count": len(learners),
                "pending_notifications": len(self.pending_notifications),
                "cache_size": len(self.response_cache)
            }), 200
    
    def _check_leader_status(self):
        """
        Verifica periodicamente o status do líder e detecta falhas.
        """
        while True:
            try:
                current_time = time.time()
                current_leader = self.gossip.get_leader()
                
                if current_leader is not None:
                    # Verificar se o líder está inativo
                    if current_time - self.last_heartbeat_time > self.leader_timeout:
                        self.logger.warning(f"Líder {current_leader} parece inativo. Último heartbeat há {current_time - self.last_heartbeat_time:.1f}s")
                        
                        # Limpar líder no gossip
                        self.gossip.set_leader(None)
                        
                        # Atualizar metadata no gossip
                        self.gossip.update_local_metadata({
                            "leader_detected_failed": current_leader,
                            "detection_time": current_time
                        })
                        
                        # Limpar líder local
                        with self.lock:
                            self.current_leader_id = None
            except Exception as e:
                self.logger.error(f"Erro ao verificar status do líder: {e}")
            
            # Verificar a cada 2 segundos
            time.sleep(2)
    
    def _notify_learners_batch(self):
        """
        Thread que envia notificações em lote para os learners periodicamente.
        """
        while True:
            try:
                # Esperar um pouco para acumular notificações
                time.sleep(1)
                
                # Verificar se temos notificações pendentes
                if self.pending_notifications:
                    self._notify_learners_now()
            except Exception as e:
                self.logger.error(f"Erro no processamento em lote de notificações: {e}")
    
    def _notify_learners_now(self):
        """
        Envia imediatamente as notificações pendentes para todos os learners.
        """
        with self.lock:
            # Obter todas as notificações pendentes
            notifications = self.pending_notifications.copy()
            self.pending_notifications = []
        
        if not notifications:
            return
        
        # Obter learners via gossip
        learners = self.gossip.get_nodes_by_role('learner')
        
        if not learners:
            self.logger.warning("Nenhum learner conhecido para notificar")
            
            # Recolocar notificações na fila
            with self.lock:
                self.pending_notifications = notifications + self.pending_notifications
            return
        
        self.logger.info(f"Notificando {len(learners)} learners sobre {len(notifications)} valores aceitos")
        
        # Para cada learner, enviar notificações
        for learner_id, learner in learners.items():
            try:
                learner_url = f"http://{learner['address']}:{learner['port']}/learn"
                
                # Enviar em thread separada para não bloquear
                threading.Thread(
                    target=self._send_notifications_to_learner,
                    args=(learner_url, notifications, learner_id)
                ).start()
            except Exception as e:
                self.logger.error(f"Erro ao preparar notificação para learner {learner_id}: {e}")
    
    def _send_notifications_to_learner(self, url, notifications, learner_id):
        """
        Envia um lote de notificações para um learner específico.
        
        Args:
            url (str): URL do learner
            notifications (list): Lista de notificações
            learner_id (str): ID do learner
        """
        # Implementar retry com backoff exponencial
        max_retries = 3
        base_timeout = 1.0
        
        for retry in range(max_retries):
            try:
                # Adicionar jitter para evitar sincronização
                timeout = base_timeout * (2 ** retry) + random.uniform(0, 0.3)
                
                # Enviar todas as notificações em um único request
                response = requests.post(
                    url, 
                    json={"notifications": notifications},
                    timeout=timeout
                )
                
                if response.status_code == 200:
                    self.logger.debug(f"Notificações enviadas com sucesso para learner {learner_id}")
                    with self.lock:
                        self.metrics["learner_notifications"] += len(notifications)
                    return
                else:
                    self.logger.warning(f"Erro ao notificar learner {learner_id}: {response.status_code} - {response.text}")
            except Exception as e:
                self.logger.error(f"Erro ao notificar learner {learner_id} (tentativa {retry+1}/{max_retries}): {e}")
                
                # Se não for a última tentativa, aguardar antes de retry
                if retry < max_retries - 1:
                    time.sleep(base_timeout * (2 ** retry) * 0.5)
        
        # Se todas as tentativas falharem, recolocar na fila
        with self.lock:
            # Recolocar apenas notificações importantes (eleições de líder)
            important_notifications = [n for n in notifications if n.get("is_leader_election", False)]
            if important_notifications:
                self.logger.warning(f"Readicionando {len(important_notifications)} notificações importantes à fila")
                self.pending_notifications = important_notifications + self.pending_notifications
    
    def _cleanup_cache(self):
        """
        Remove entradas antigas do cache periodicamente.
        """
        while True:
            try:
                time.sleep(self.cache_cleanup_interval)
                
                current_time = time.time()
                expired_keys = []
                
                with self.lock:
                    # Identificar entradas expiradas
                    for key, (response, timestamp) in list(self.response_cache.items()):
                        if current_time - timestamp > self.cache_ttl:
                            expired_keys.append(key)
                    
                    # Remover entradas expiradas
                    for key in expired_keys:
                        del self.response_cache[key]
                
                if expired_keys:
                    self.logger.debug(f"Limpeza de cache: removidas {len(expired_keys)} entradas expiradas")
            except Exception as e:
                self.logger.error(f"Erro na limpeza do cache: {e}")
    
    def _handle_view_logs(self):
        """
        Manipulador para a rota view-logs (para debugging).
        """
        learners = self.gossip.get_nodes_by_role('learner')
        
        return jsonify({
            "id": self.node_id,
            "role": self.node_role,
            "state": {
                "max_promised": self.max_promised,
                "max_accepted": self.max_accepted,
                "accepted_value": self.accepted_value
            },
            "current_leader": self.gossip.get_leader(),
            "metrics": self.metrics,
            "learners_count": len(learners),
            "known_nodes_count": len(self.gossip.get_all_nodes())
        }), 200

# Para uso como aplicação independente
if __name__ == '__main__':
    acceptor = Acceptor()
    acceptor.start()