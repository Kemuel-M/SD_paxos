import json
import time
import threading
import logging
import random
import requests
from flask import request, jsonify
from enum import Enum

from base_node import BaseNode

class ProposerState(Enum):
    """Estados possíveis para um Proposer no sistema Paxos"""
    FOLLOWER = "follower"  # Nó seguidor (não-líder)
    CANDIDATE = "candidate"  # Em processo de eleição
    LEADER = "leader"  # Líder atual

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
        
        # Estado do proposer
        self.state = ProposerState.FOLLOWER
        self.current_leader = None
        
        # Contador para geração de números de proposta
        self.proposal_counter = 0
        
        # Controle de eleição
        self.election_in_progress = False
        self.election_start_time = 0
        self.election_timeout = 5  # segundos
        
        # Controle de heartbeat
        self.heartbeat_interval = 1.0  # segundos
        self.last_heartbeat_received = 0
        self.leader_timeout = 5.0  # segundos para considerar o líder como falho
        
        # Backoff para evitar tempestade de eleições
        self.backoff_time = 0  # tempo até a próxima tentativa de eleição
        self.max_backoff = 10  # backoff máximo em segundos
        self.base_backoff = 1  # backoff base em segundos
        
        # Controle de proposta atual
        self.current_proposal_number = 0
        self.proposed_value = None
        self.proposal_accepted_count = 0
        self.waiting_for_acceptor_response = False
        
        # Fila de propostas pendentes
        self.pending_proposals = []
        
        # Controle de inicialização
        self.bootstrap_completed = False
        self.bootstrap_delay = 5 * (1 + 0.5 * self.node_id)  # Atraso proporcional ao ID
        
        # Histórico para monitoramento
        self.proposal_history = []  # Últimas propostas
        self.leader_history = []    # Histórico de líderes
        self.metrics = {
            "election_count": 0,
            "proposal_count": 0,
            "accept_count": 0,
            "reject_count": 0,
            "heartbeat_sent": 0,
            "heartbeat_received": 0
        }
        
        self.logger.info(f"Proposer inicializado com ID {self.node_id}")
    
    def _get_default_port(self):
        """Retorna a porta padrão para proposers"""
        return 3000
    
    def _register_routes(self):
        """Registra as rotas específicas do proposer"""
        @self.app.route('/propose', methods=['POST'])
        def propose():
            """Receber proposta de um cliente"""
            return self._handle_propose(request.json)
        
        @self.app.route('/heartbeat', methods=['POST'])
        def heartbeat():
            """Receber heartbeat do líder"""
            return self._handle_heartbeat(request.json)
        
        @self.app.route('/status', methods=['GET'])
        def status():
            """Retorna o status atual do proposer"""
            return self._handle_status()
    
    def _start_threads(self):
        """Inicia as threads do proposer"""
        # Thread para monitorar o líder e iniciar eleições
        threading.Thread(target=self._leader_monitor_loop, daemon=True).start()
        
        # Thread para enviar heartbeats quando for líder
        threading.Thread(target=self._heartbeat_loop, daemon=True).start()
        
        # Thread para processar propostas pendentes
        threading.Thread(target=self._proposal_processor_loop, daemon=True).start()
        
        # Thread para bootstrap inicial
        threading.Thread(target=self._bootstrap, daemon=True).start()
    
    def _bootstrap(self):
        """
        Realiza o bootstrap inicial do proposer, aguardando um tempo proporcional
        ao ID antes de tentar iniciar uma eleição se nenhum líder for detectado.
        """
        self.logger.info(f"Iniciando bootstrap com delay de {self.bootstrap_delay:.1f}s")
        time.sleep(self.bootstrap_delay)
        
        # Verificar se já existe um líder
        current_leader = self.gossip.get_leader()
        
        if current_leader is not None:
            self.logger.info(f"Líder {current_leader} detectado durante bootstrap")
            self.current_leader = current_leader
            self.state = ProposerState.FOLLOWER
        else:
            # Nenhum líder detectado, iniciar eleição
            self.logger.info("Nenhum líder detectado após bootstrap, iniciando eleição")
            self._start_election()
        
        self.bootstrap_completed = True
    
    def _leader_monitor_loop(self):
        """
        Loop contínuo que monitora o status do líder e inicia
        eleições quando necessário.
        """
        while True:
            try:
                current_time = time.time()
                current_leader = self.gossip.get_leader()
                
                # Atualizar o líder conhecido
                if self.current_leader != current_leader:
                    old_leader = self.current_leader
                    self.current_leader = current_leader
                    
                    if old_leader is not None and current_leader is None:
                        self.logger.warning(f"Líder {old_leader} removido")
                    elif current_leader is not None:
                        self.logger.info(f"Novo líder reconhecido: {current_leader}")
                        
                        # Registrar no histórico
                        self.leader_history.append({
                            "leader_id": current_leader,
                            "start_time": current_time
                        })
                        
                        # Limitar tamanho do histórico
                        if len(self.leader_history) > 10:
                            self.leader_history = self.leader_history[-10:]
                    
                    # Atualizar estado conforme o líder
                    if current_leader == self.node_id:
                        if self.state != ProposerState.LEADER:
                            self.logger.info(f"Este nó agora é o líder")
                            self.state = ProposerState.LEADER
                    else:
                        if self.state == ProposerState.LEADER:
                            self.logger.info(f"Este nó não é mais o líder")
                            self.state = ProposerState.FOLLOWER
                
                # Verificar se estamos sem líder e não em eleição
                if current_leader is None and not self.election_in_progress:
                    # Verificar se já passou o tempo de backoff
                    if current_time > self.backoff_time and self.bootstrap_completed:
                        self.logger.info("Sem líder detectado e backoff expirado, iniciando eleição")
                        self._start_election()
                
                # Se sou o líder, verificar se ainda estou registrado como tal
                if self.state == ProposerState.LEADER:
                    if current_leader != self.node_id:
                        self.logger.warning(f"Estado inconsistente! Sou líder mas gossip indica {current_leader}")
                        # Atualizar gossip para refletir liderança
                        self.gossip.set_leader(self.node_id)
                
                # Se sou follower, verificar timeout do líder
                elif self.state == ProposerState.FOLLOWER and current_leader is not None:
                    # Verificar quando foi o último heartbeat recebido
                    if current_time - self.last_heartbeat_received > self.leader_timeout:
                        self.logger.warning(f"Timeout do líder {current_leader} detectado")
                        
                        # Limpar o líder no gossip
                        self.gossip.set_leader(None)
                        
                        # Calcular backoff com jitter para evitar eleições simultâneas
                        jitter = random.uniform(0, 1.0)
                        backoff = min(self.base_backoff * (2 ** self.metrics["election_count"] % 5), self.max_backoff)
                        self.backoff_time = current_time + backoff + (jitter * self.node_id)
                        
                        self.logger.info(f"Backoff para próxima eleição: {backoff + jitter*self.node_id:.2f}s")
            except Exception as e:
                self.logger.error(f"Erro no monitor de líder: {e}")
            
            # Verificar a cada 1 segundo
            time.sleep(1.0)
    
    def _heartbeat_loop(self):
        """
        Envia heartbeats periódicos quando este nó é o líder.
        """
        while True:
            try:
                # Verificar se sou o líder
                if self.state == ProposerState.LEADER:
                    self._send_heartbeat_to_all_proposers()
                    self.metrics["heartbeat_sent"] += 1
                    
                    # Atualizar metadata no gossip
                    self.gossip.update_local_metadata({
                        "is_leader": True,
                        "last_heartbeat": time.time(),
                        "proposal_count": self.metrics["proposal_count"]
                    })
            except Exception as e:
                self.logger.error(f"Erro no loop de heartbeat: {e}")
            
            # Enviar heartbeats no intervalo configurado
            time.sleep(self.heartbeat_interval)
    
    def _proposal_processor_loop(self):
        """
        Processa as propostas pendentes quando este nó é o líder.
        """
        while True:
            try:
                # Verificar se sou o líder e tenho propostas pendentes
                if self.state == ProposerState.LEADER and self.pending_proposals and not self.waiting_for_acceptor_response:
                    # Obter a próxima proposta
                    next_proposal = self.pending_proposals.pop(0)
                    self.logger.info(f"Processando proposta pendente: {next_proposal['value']}")
                    
                    # Processar a proposta
                    self._process_proposal(next_proposal['value'], next_proposal['client_id'], 
                                          is_leader_election=False)
            except Exception as e:
                self.logger.error(f"Erro no processador de propostas: {e}")
            
            # Verificar a cada 0.5 segundos
            time.sleep(0.5)
    
    def _handle_status(self):
        """
        Retorna informações detalhadas sobre o status atual do proposer.
        """
        acceptors = self.gossip.get_nodes_by_role('acceptor')
        learners = self.gossip.get_nodes_by_role('learner')
        
        return jsonify({
            "id": self.node_id,
            "role": self.node_role,
            "state": self.state.value,
            "current_leader": self.current_leader,
            "is_leader": self.state == ProposerState.LEADER,
            "election_in_progress": self.election_in_progress,
            "bootstrap_completed": self.bootstrap_completed,
            "proposal_counter": self.proposal_counter,
            "acceptors_count": len(acceptors),
            "learners_count": len(learners),
            "pending_proposals": len(self.pending_proposals),
            "metrics": self.metrics,
            "last_heartbeat_received": self.last_heartbeat_received,
            "current_proposal": {
                "number": self.current_proposal_number,
                "value": self.proposed_value,
                "accepted_count": self.proposal_accepted_count,
                "waiting_for_response": self.waiting_for_acceptor_response
            }
        }), 200
    
    def _handle_heartbeat(self, data):
        """
        Processa heartbeats recebidos do líder atual.
        
        Args:
            data (dict): Dados do heartbeat
        
        Returns:
            Response: Resposta HTTP
        """
        leader_id = data.get('leader_id')
        timestamp = data.get('timestamp', time.time())
        first_heartbeat = data.get('first_heartbeat', False)
        
        if leader_id is None:
            return jsonify({"error": "Missing leader_id"}), 400
        
        # Atualizar último heartbeat recebido
        self.last_heartbeat_received = time.time()
        self.metrics["heartbeat_received"] += 1
        
        # Se o líder é diferente do atual, atualizar
        if self.current_leader != leader_id:
            old_leader = self.current_leader
            self.current_leader = leader_id
            
            # Atualizar o líder no gossip
            self.gossip.set_leader(leader_id)
            
            self.logger.info(f"Líder atualizado via heartbeat: {old_leader} -> {leader_id}")
            
            # Se eu pensava que era o líder, mas recebi heartbeat de outro
            if self.state == ProposerState.LEADER and leader_id != self.node_id:
                self.logger.warning(f"Conflito de liderança! Voltando para estado FOLLOWER")
                self.state = ProposerState.FOLLOWER
        
        # Se é o primeiro heartbeat do líder, registrar
        if first_heartbeat:
            self.logger.info(f"Recebido primeiro heartbeat do líder {leader_id}")
            
            # Registrar no histórico
            self.leader_history.append({
                "leader_id": leader_id,
                "start_time": timestamp
            })
        
        # Responder com acknowledgment
        return jsonify({
            "status": "acknowledged",
            "from_proposer": self.node_id,
            "received_at": time.time()
        }), 200
    
    def _handle_propose(self, data):
        """
        Processa requisições de proposta recebidas dos clientes.
        
        Args:
            data (dict): Dados da requisição
        
        Returns:
            Response: Resposta HTTP
        """
        value = data.get('value')
        client_id = data.get('client_id')
        is_leader_election = data.get('is_leader_election', False)
        force_election = "force_election" in str(value).lower() if value else False
        
        if not value:
            return jsonify({"error": "Value required"}), 400
        
        # Se é uma requisição para forçar eleição
        if force_election or is_leader_election:
            self.logger.info(f"Recebida solicitação para forçar eleição")
            election_started = self._start_election()
            
            if election_started:
                return jsonify({
                    "status": "election_started",
                    "proposer_id": self.node_id
                }), 200
            else:
                return jsonify({
                    "status": "election_already_in_progress",
                    "proposer_id": self.node_id
                }), 200
        
        # Verificar se sou o líder ou se não há líder
        if self.state == ProposerState.LEADER:
            # Sou o líder, processar proposta
            self.logger.info(f"Recebida proposta como líder: {value} do cliente {client_id}")
            
            # Se já estou processando uma proposta, adicionar à fila
            if self.waiting_for_acceptor_response:
                self.logger.info(f"Adicionando proposta à fila: {value}")
                self.pending_proposals.append({
                    "value": value,
                    "client_id": client_id,
                    "timestamp": time.time()
                })
                
                return jsonify({
                    "status": "queued",
                    "position": len(self.pending_proposals),
                    "leader": self.node_id
                }), 200
            else:
                # Processar proposta imediatamente
                return self._process_proposal(value, client_id)
        
        else:
            # Não sou o líder, redirecionar para o líder se conhecido
            if self.current_leader is not None:
                self.logger.info(f"Redirecionando proposta para o líder {self.current_leader}")
                
                # Tentar redirecionar para o líder
                try:
                    leader_info = self.gossip.get_node_info(str(self.current_leader))
                    if leader_info:
                        leader_url = f"http://{leader_info['address']}:{leader_info['port']}/propose"
                        try:
                            response = requests.post(leader_url, json=data, timeout=3)
                            if response.status_code == 200:
                                return response.json(), 200
                            else:
                                self.logger.warning(f"Líder retornou erro: {response.status_code}")
                        except Exception as e:
                            self.logger.error(f"Erro ao contatar líder: {e}")
                            # Líder inatingível, iniciar nova eleição
                            self.gossip.set_leader(None)
                except Exception as e:
                    self.logger.error(f"Erro ao obter info do líder: {e}")
            
            # Se não há líder ou ocorreu erro no redirecionamento
            # Informar ao cliente que não sou o líder
            return jsonify({
                "error": "Not the leader",
                "current_leader": self.current_leader,
                "retry_suggested": True
            }), 409  # Conflict
    
    def _process_proposal(self, value, client_id, is_leader_election=False):
        """
        Processa uma proposta, enviando-a para os acceptors.
        
        Args:
            value (str): Valor a ser proposto
            client_id (int): ID do cliente
            is_leader_election (bool): Se é proposta de eleição
        
        Returns:
            Response: Resposta HTTP ou None se chamado internamente
        """
        with self.lock:
            if self.waiting_for_acceptor_response and not is_leader_election:
                self.logger.warning("Já processando uma proposta")
                return jsonify({"error": "Already processing a proposal"}), 429
            
            self.waiting_for_acceptor_response = True
            self.proposed_value = value
            
            # Incrementar contador e gerar número único de proposta
            self.proposal_counter += 1
            self.current_proposal_number = self.proposal_counter * 100 + self.node_id
            self.proposal_accepted_count = 0
            
            self.metrics["proposal_count"] += 1
            
            # Adicionar ao histórico
            self.proposal_history.append({
                "number": self.current_proposal_number,
                "value": value,
                "timestamp": time.time(),
                "is_election": is_leader_election
            })
            
            # Limitar tamanho do histórico
            if len(self.proposal_history) > 20:
                self.proposal_history = self.proposal_history[-20:]
        
        # Registrar tipo de proposta
        if is_leader_election:
            self.logger.info(f"Iniciando proposta de eleição {self.current_proposal_number}")
        else:
            self.logger.info(f"Iniciando proposta normal {self.current_proposal_number}: {value}")
        
        # Obter acceptors via gossip
        acceptors = self.gossip.get_nodes_by_role('acceptor')
        quorum_size = len(acceptors) // 2 + 1
        
        if not acceptors:
            self.logger.error("Nenhum acceptor disponível")
            with self.lock:
                self.waiting_for_acceptor_response = False
            return jsonify({"error": "No acceptors available"}), 503
        
        self.logger.info(f"Enviando PREPARE para {len(acceptors)} acceptors (quorum={quorum_size})")
        
        # Enviar mensagem PREPARE para todos os acceptors (fase 1)
        threads = []
        for acceptor_id, acceptor in acceptors.items():
            acceptor_url = f"http://{acceptor['address']}:{acceptor['port']}/prepare"
            prepare_data = {
                "proposer_id": self.node_id,
                "proposal_number": self.current_proposal_number,
                "is_leader_election": is_leader_election
            }
            
            thread = threading.Thread(
                target=self._send_prepare,
                args=(acceptor_url, prepare_data, quorum_size, value, client_id, is_leader_election)
            )
            threads.append(thread)
            thread.start()
        
        # Se chamado de _handle_propose, retornar resposta ao cliente
        if not is_leader_election:
            return jsonify({
                "status": "proposal_initiated",
                "proposal_number": self.current_proposal_number,
                "proposer_id": self.node_id
            }), 200
    
    def _send_prepare(self, url, data, quorum_size, value, client_id, is_leader_election):
        """
        Envia uma mensagem PREPARE para um acceptor e processa a resposta.
        
        Args:
            url (str): URL do acceptor
            data (dict): Dados do PREPARE
            quorum_size (int): Tamanho do quórum necessário
            value (str): Valor proposto
            client_id (int): ID do cliente
            is_leader_election (bool): Se é eleição de líder
        """
        max_retries = 3
        base_timeout = 1.0
        
        for retry in range(max_retries):
            try:
                # Adicionar jitter para evitar sincronização
                timeout = base_timeout + (retry * 0.5) + random.uniform(0, 0.2)
                
                response = requests.post(url, json=data, timeout=timeout)
                
                if response.status_code == 200:
                    result = response.json()
                    
                    if result.get("status") == "promise":
                        # O acceptor prometeu
                        with self.lock:
                            self.proposal_accepted_count += 1
                            
                            if is_leader_election:
                                self.logger.info(f"PROMISE recebido para eleição: {self.proposal_accepted_count}/{quorum_size}")
                            else:
                                self.logger.info(f"PROMISE recebido para proposta: {self.proposal_accepted_count}/{quorum_size}")
                            
                            # Se atingimos o quórum, prosseguir para fase 2 (ACCEPT)
                            if self.proposal_accepted_count >= quorum_size:
                                if is_leader_election:
                                    # Eleição bem-sucedida na fase 1
                                    self.logger.info(f"Quórum de PROMISE atingido para eleição!")
                                    
                                    # Enviar ACCEPT para todos com valor de liderança
                                    self._send_accept_to_all(f"leader:{self.node_id}", client_id, is_leader_election)
                                    
                                    # Atualizar estado para LEADER
                                    self.state = ProposerState.LEADER
                                    self.election_in_progress = False
                                    
                                    # Atualizar gossip
                                    self.gossip.set_leader(self.node_id)
                                    self.gossip.update_local_metadata({
                                        "is_leader": True,
                                        "last_heartbeat": time.time()
                                    })
                                    
                                    # Enviar heartbeat imediatamente para anunciar liderança
                                    self._send_heartbeat_to_all_proposers(first_heartbeat=True)
                                    
                                elif self.waiting_for_acceptor_response:
                                    # Proposta normal atingiu quórum na fase 1
                                    self.logger.info(f"Quórum de PROMISE atingido para proposta!")
                                    
                                    # Verificar se algum acceptor já aceitou um valor
                                    # Em caso positivo, devemos propor esse valor
                                    # (Requisito de Paxos para garantir propriedade de segurança)
                                    highest_accepted = None
                                    highest_proposal = 0
                                    
                                    for acc_id, acc_resp in self.acceptor_responses.items():
                                        accepted_num = acc_resp.get("accepted_proposal_number", 0)
                                        if accepted_num > highest_proposal and acc_resp.get("accepted_value"):
                                            highest_proposal = accepted_num
                                            highest_accepted = acc_resp.get("accepted_value")
                                    
                                    # Se algum valor foi previamente aceito, devemos propô-lo
                                    if highest_accepted:
                                        self.logger.info(f"Usando valor anteriormente aceito: {highest_accepted}")
                                        value = highest_accepted
                                    
                                    # Enviar ACCEPT para todos com o valor (fase 2)
                                    self._send_accept_to_all(value, client_id, is_leader_election)
                    else:
                        # O acceptor rejeitou
                        reason = result.get("message", "Sem motivo informado")
                        self.logger.warning(f"PREPARE rejeitado: {reason}")
                        
                        if is_leader_election and "higher proposal number" in reason:
                            # Outro proposer tem número maior, abortar esta eleição
                            with self.lock:
                                self.election_in_progress = False
                                self.metrics["reject_count"] += 1
                            
                            self.logger.warning(f"Abortando eleição devido a proposta com número maior")
                            break
                
                # Se obtivemos resposta, não precisamos mais de retry
                break
                
            except Exception as e:
                self.logger.error(f"Erro ao enviar PREPARE (tentativa {retry+1}/{max_retries}): {e}")
                
                # Última tentativa falhou
                if retry == max_retries - 1:
                    if is_leader_election:
                        with self.lock:
                            self.election_in_progress = False
                    else:
                        with self.lock:
                            self.waiting_for_acceptor_response = False
    
    def _send_accept_to_all(self, value, client_id, is_leader_election):
        """
        Envia mensagens ACCEPT para todos os acceptors (fase 2 do Paxos).
        
        Args:
            value (str): Valor a propor
            client_id (int): ID do cliente
            is_leader_election (bool): Se é eleição de líder
        """
        acceptors = self.gossip.get_nodes_by_role('acceptor')
        
        self.logger.info(f"Enviando ACCEPT para {len(acceptors)} acceptors com valor: {value}")
        
        for acceptor_id, acceptor in acceptors.items():
            try:
                acceptor_url = f"http://{acceptor['address']}:{acceptor['port']}/accept"
                accept_data = {
                    "proposer_id": self.node_id,
                    "proposal_number": self.current_proposal_number,
                    "value": value,
                    "client_id": client_id,
                    "is_leader_election": is_leader_election
                }
                
                threading.Thread(
                    target=self._send_accept, 
                    args=(acceptor_url, accept_data)
                ).start()
            except Exception as e:
                self.logger.error(f"Erro ao enviar ACCEPT para acceptor {acceptor_id}: {e}")
        
        # Após enviar todos os ACCEPTs, podemos limpar o flag de espera
        with self.lock:
            if not is_leader_election:
                self.waiting_for_acceptor_response = False
    
    def _send_accept(self, url, data):
        """
        Envia uma mensagem ACCEPT para um acceptor.
        
        Args:
            url (str): URL do acceptor
            data (dict): Dados do ACCEPT
        """
        max_retries = 3
        base_timeout = 1.0
        
        for retry in range(max_retries):
            try:
                # Adicionar jitter para evitar sincronização
                timeout = base_timeout + (retry * 0.5) + random.uniform(0, 0.2)
                
                response = requests.post(url, json=data, timeout=timeout)
                
                if response.status_code == 200:
                    result = response.json()
                    
                    if result.get("status") == "accepted":
                        self.logger.info(f"ACCEPT aceito pelo acceptor")
                        self.metrics["accept_count"] += 1
                    else:
                        reason = result.get("message", "Sem motivo informado")
                        self.logger.warning(f"ACCEPT rejeitado: {reason}")
                        self.metrics["reject_count"] += 1
                
                # Se obtivemos resposta, não precisamos mais de retry
                break
                
            except Exception as e:
                self.logger.error(f"Erro ao enviar ACCEPT (tentativa {retry+1}/{max_retries}): {e}")
    
    def _send_heartbeat_to_all_proposers(self, first_heartbeat=False):
        """
        Envia heartbeats para todos os outros proposers.
        
        Args:
            first_heartbeat (bool): Se é o primeiro heartbeat após eleição
        """
        if self.state != ProposerState.LEADER:
            return
        
        proposers = self.gossip.get_nodes_by_role('proposer')
        current_time = time.time()
        
        heartbeat_data = {
            "leader_id": self.node_id,
            "timestamp": current_time,
            "first_heartbeat": first_heartbeat
        }
        
        for proposer_id, proposer in proposers.items():
            if proposer_id != str(self.node_id):  # Não enviar para si mesmo
                try:
                    proposer_url = f"http://{proposer['address']}:{proposer['port']}/heartbeat"
                    
                    threading.Thread(
                        target=lambda url, data: requests.post(url, json=data, timeout=1),
                        args=(proposer_url, heartbeat_data)
                    ).start()
                except Exception as e:
                    self.logger.debug(f"Erro ao preparar heartbeat para proposer {proposer_id}: {e}")
    
    def _start_election(self):
        """
        Inicia o processo de eleição de líder.
        
        Returns:
            bool: True se a eleição foi iniciada, False caso contrário
        """
        with self.lock:
            # Verificar se já estamos em eleição
            if self.election_in_progress:
                self.logger.info("Eleição já em andamento, ignorando solicitação")
                return False
            
            # Marcar como em eleição
            self.election_in_progress = True
            self.election_start_time = time.time()
            self.metrics["election_count"] += 1
            
            # Mudar estado para CANDIDATE
            self.state = ProposerState.CANDIDATE
            
            # Gerar número de proposta para eleição: timestamp + ID
            # Usar timestamp para garantir unicidade e resolver conflitos
            self.current_proposal_number = int(time.time() * 1000) + self.node_id
        
        self.logger.info(f"Iniciando eleição com proposta número {self.current_proposal_number}")
        
        # Iniciar processo Multi-Paxos para eleição
        self._process_proposal(f"leader:{self.node_id}", None, is_leader_election=True)
        
        return True
    
    def _handle_view_logs(self):
        """
        Fornece logs e estado interno para debugging.
        """
        acceptors = self.gossip.get_nodes_by_role('acceptor')
        learners = self.gossip.get_nodes_by_role('learner')
        
        return jsonify({
            "id": self.node_id,
            "role": self.node_role,
            "state": self.state.value,
            "is_leader": self.state == ProposerState.LEADER,
            "current_leader": self.current_leader, 
            "election_in_progress": self.election_in_progress,
            "bootstrap_completed": self.bootstrap_completed,
            "proposal_counter": self.proposal_counter,
            "acceptors_count": len(acceptors),
            "learners_count": len(learners),
            "known_nodes_count": len(self.gossip.get_all_nodes()),
            "pending_proposals": len(self.pending_proposals),
            "metrics": self.metrics,
            "current_proposal": {
                "number": self.current_proposal_number,
                "value": self.proposed_value,
                "accepted_count": self.proposal_accepted_count,
                "waiting_for_response": self.waiting_for_acceptor_response
            },
            "recent_proposals": self.proposal_history[-5:] if self.proposal_history else []
        }), 200

# Para uso como aplicação independente
if __name__ == '__main__':
    proposer = Proposer()
    proposer.start()