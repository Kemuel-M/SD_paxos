import json
import time
import threading
import logging
import random
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
        
        # Valores para detecção de falha e recuperação
        self.heartbeat_interval = 2  # segundos para enviar heartbeat
        self.leader_timeout = 8  # segundos sem heartbeat para considerar o líder como falho
        self.last_heartbeat_received = 0  # timestamp do último heartbeat recebido
        
        # Timeout adaptativo com backoff
        self.backoff_time = 0  # tempo de backoff para evitar tempestade de eleições
        self.max_backoff = 10  # máximo backoff em segundos
        self.base_backoff = 1  # backoff base em segundos
        
        # Valores de proposta atual
        self.current_proposal_number = 0
        self.proposed_value = None
        self.proposal_accepted_count = 0
        self.waiting_for_acceptor_response = False
        
        # Bootstrap e recuperação
        self.bootstrap_mode = True  # Iniciar em modo bootstrap
        self.bootstrap_attempts = 0
        self.max_bootstrap_attempts = 3
        self.initial_bootstrap_delay = 5  # Atraso inicial (segundos)
    
    def _get_default_port(self):
        """Porta padrão para proposers"""
        return 3000
    
    def _register_routes(self):
        """Registrar rotas específicas do proposer"""
        @self.app.route('/propose', methods=['POST'])
        def propose():
            """Receber proposta de um cliente"""
            return self._handle_propose(request.json)
        
        @self.app.route('/heartbeat', methods=['POST'])
        def heartbeat():
            """Receber heartbeat do líder"""
            return self._handle_heartbeat(request.json)
    
    def _start_threads(self):
        """Iniciar threads específicas do proposer"""
        # Thread de verificação de líder e bootstrap
        threading.Thread(target=self._check_leader, daemon=True).start()
        
        # Thread de heartbeat de líder
        threading.Thread(target=self._leader_heartbeat, daemon=True).start()
        
        # Thread para bootstrap inicial
        if self.bootstrap_mode:
            # Aguardar um pouco para que todos os nós inicializem
            threading.Thread(target=self._bootstrap_election, daemon=True).start()
    
    def _bootstrap_election(self):
        """Inicia o processo de bootstrap para eleição inicial de líder"""
        # MODIFICAÇÃO: Aumentar o tempo de espera inicial para permitir descoberta de nós
        # Esperar para dar tempo aos outros nós de inicializar
        initial_delay = self.initial_bootstrap_delay * 3  # Aumentar em 3x
        self.logger.info(f"Aguardando {initial_delay}s para bootstrap iniciar...")
        time.sleep(initial_delay)
        
        self.logger.info("Iniciando processo de bootstrap para eleição inicial")
        
        # Verificar se já existe um líder
        current_leader = self.gossip.get_leader()
        if current_leader is not None:
            self.logger.info(f"Líder já existe durante bootstrap: {current_leader}")
            self.bootstrap_mode = False
            return
        
        # MODIFICAÇÃO: Log detalhado de nós conhecidos para debug
        acceptors = self.gossip.get_nodes_by_role('acceptor')
        self.logger.info(f"Acceptors conhecidos antes da eleição: {len(acceptors)}")
        for aid, ainfo in acceptors.items():
            self.logger.info(f"  Acceptor {aid}: {ainfo['address']}:{ainfo['port']}")
        
        # Pequeno atraso proporcional ao ID do nó para evitar sobreposição
        # Proposers com IDs mais baixos iniciam primeiro
        startup_delay = self.node_id * 1.0
        time.sleep(startup_delay)
        
        # Verificar novamente se algum outro já se tornou líder
        current_leader = self.gossip.get_leader()
        if current_leader is not None:
            self.logger.info(f"Líder eleito durante atraso de bootstrap: {current_leader}")
            self.bootstrap_mode = False
            return
        
        # Iniciar eleição
        self.logger.info("Iniciando eleição inicial de bootstrap")
        
        # Em bootstrap, usar um número de proposta determinístico baseado no ID
        # para dar prioridade a proposers com ID mais baixo
        with self.lock:
            self.proposal_counter = 1000  # Iniciar com valor alto para bootstrap
            # Menor ID obtém maior prioridade na fase inicial
            self.current_proposal_number = self.proposal_counter - self.node_id
        
        # Iniciar processo de eleição
        self._start_election(bootstrap=True)
        
        # Após bootstrap, desativar modo bootstrap independente do resultado
        self.bootstrap_attempts += 1
        if self.bootstrap_attempts >= self.max_bootstrap_attempts:
            self.bootstrap_mode = False

    
    def _handle_heartbeat(self, data):
        """
        Manipula heartbeats recebidos do líder
        
        Args:
            data (dict): Dados do heartbeat
        
        Returns:
            Response: Resposta HTTP
        """
        leader_id = data.get('leader_id')
        timestamp = data.get('timestamp', time.time())
        
        if leader_id:
            # Atualizar timestamp do último heartbeat
            self.last_heartbeat_received = timestamp
            self.logger.debug(f"Heartbeat recebido do líder {leader_id}")
            
            # Atualizar o líder no gossip se necessário
            current_leader = self.gossip.get_leader()
            if current_leader != leader_id:
                self.gossip.set_leader(leader_id)
                self.logger.info(f"Líder atualizado para {leader_id} via heartbeat")
            
            # Sair do modo bootstrap se estiver nele
            if self.bootstrap_mode:
                self.bootstrap_mode = False
                self.logger.info("Saindo do modo bootstrap após receber heartbeat de líder")
            
            return jsonify({"status": "acknowledged"}), 200
        
        return jsonify({"error": "Invalid heartbeat data"}), 400
    
    def _handle_propose(self, data):
        """
        Manipula requisições de proposta de clientes.
        
        Args:
            data (dict): Dados da proposta do cliente
        
        Returns:
            Response: Resposta HTTP
        """
        # Verificar se este nó é o líder ou se estamos em bootstrap
        current_leader = self.gossip.get_leader()
        is_leader = current_leader is not None and int(current_leader) == self.node_id
        
        # Permitir propostas durante bootstrap ou se for líder
        can_propose = is_leader or self.bootstrap_mode or current_leader is None
        
        # Se não pode propor, redirecionar para o líder
        if not can_propose:
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
        is_leader_election = data.get('is_leader_election', False)
        
        if not value:
            return jsonify({"error": "Value required"}), 400
        
        with self.lock:
            if self.waiting_for_acceptor_response and not self.bootstrap_mode and not is_leader_election:
                return jsonify({"error": "Already processing a proposal"}), 429
            
            self.waiting_for_acceptor_response = True
            self.proposed_value = value
            
            # Incrementar contador de propostas e gerar número de proposta único
            self.proposal_counter += 1
            if is_leader_election or self.bootstrap_mode:
                # Para eleição de líder, usar número baseado em timestamp para ser único
                self.current_proposal_number = int(time.time() * 100) + self.node_id
            else:
                # Para propostas normais
                self.current_proposal_number = self.proposal_counter * 100 + self.node_id
                
            self.proposal_accepted_count = 0
        
        # Registrar tipo de proposta
        if is_leader_election:
            self.logger.info(f"Iniciando eleição de líder com proposta {self.current_proposal_number}")
        elif self.bootstrap_mode:
            self.logger.info(f"Proposta em modo bootstrap do cliente {client_id}: {value} (proposta {self.current_proposal_number})")
        else:
            self.logger.info(f"Proposta normal do cliente {client_id}: {value} (proposta {self.current_proposal_number})")
        
        # Enviar prepare para todos os acceptors
        try:
            acceptors = self.gossip.get_nodes_by_role('acceptor')
            quorum_size = len(acceptors) // 2 + 1
            
            if quorum_size == 0:
                with self.lock:
                    self.waiting_for_acceptor_response = False
                return jsonify({"error": "No acceptors available"}), 503
            
            self.logger.info(f"Enviando prepare para {len(acceptors)} acceptors (quorum: {quorum_size})")
            
            for acceptor_id, acceptor in acceptors.items():
                try:
                    acceptor_url = f"http://{acceptor['address']}:{acceptor['port']}/prepare"
                    prepare_data = {
                        "proposer_id": self.node_id,
                        "proposal_number": self.current_proposal_number,
                        "is_leader_election": is_leader_election
                    }
                    
                    threading.Thread(target=self._send_prepare_with_retry, args=(
                        acceptor_url, prepare_data, quorum_size, value, client_id, is_leader_election)).start()
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
                current_time = time.time()
                
                with self.lock:
                    # Se não houver líder e não estiver em bootstrap, iniciar eleição
                    if current_leader is None and not self.in_election and not self.bootstrap_mode:
                        # Verificar se já passou o tempo de backoff
                        if current_time > self.backoff_time:
                            self.logger.info("Sem líder detectado, iniciando eleição")
                            self._start_election()
                    
                    # Se este nó for o líder, enviar heartbeat
                    elif current_leader is not None and int(current_leader) == self.node_id:
                        self.gossip.update_local_metadata({
                            "is_leader": True,
                            "last_heartbeat": current_time
                        })
                        self.logger.debug("Este nó é o líder atual")
                    
                    # Se outro nó for o líder, verificar timeout de heartbeat
                    elif current_leader is not None and int(current_leader) != self.node_id:
                        leader_info = self.gossip.get_node_info(str(current_leader))
                        if leader_info and leader_info.get('metadata'):
                            last_heartbeat = leader_info.get('metadata').get('last_heartbeat', 0)
                            
                            # Se o último heartbeat foi há muito tempo, considerar o líder como falho
                            if current_time - last_heartbeat > self.leader_timeout:
                                self.logger.warning(f"Timeout do líder {current_leader}. Iniciando nova eleição.")
                                
                                # Adicionar backoff exponencial com jitter para evitar tempestade de eleições
                                jitter = random.uniform(0.1, 0.5)
                                backoff = min(self.base_backoff * (2 ** self.bootstrap_attempts), self.max_backoff)
                                self.backoff_time = current_time + backoff + jitter
                                
                                self.logger.info(f"Backoff para eleição: {backoff + jitter:.2f} segundos")
                                self._start_election()
                        
                        # Atualizar status de líder local se necessário
                        local_info = self.gossip.get_node_info(str(self.node_id))
                        if local_info and local_info.get('metadata', {}).get('is_leader', False):
                            self.gossip.update_local_metadata({"is_leader": False})
            except Exception as e:
                self.logger.error(f"Erro ao verificar líder: {e}")
            
            time.sleep(2)  # Verificar a cada 2 segundos
    
    def _leader_heartbeat(self):
        """Enviar heartbeat como líder para os outros nós"""
        while True:
            try:
                # Verificar se este nó é o líder
                is_leader = False
                current_leader = self.gossip.get_leader()
                current_time = time.time()
                
                if current_leader is not None and int(current_leader) == self.node_id:
                    is_leader = True
                    
                    # Atualizar metadata no Gossip
                    self.gossip.update_local_metadata({
                        "is_leader": True,
                        "last_heartbeat": current_time
                    })
                    
                    # Enviar heartbeat para todos os proposers
                    proposers = self.gossip.get_nodes_by_role('proposer')
                    for proposer_id, proposer in proposers.items():
                        if proposer_id != str(self.node_id):  # Não enviar para si mesmo
                            try:
                                proposer_url = f"http://{proposer['address']}:{proposer['port']}/heartbeat"
                                heartbeat_data = {
                                    "leader_id": self.node_id,
                                    "timestamp": current_time
                                }
                                
                                # Usar thread para não bloquear
                                threading.Thread(target=self._send_heartbeat, 
                                               args=(proposer_url, heartbeat_data)).start()
                            except Exception as e:
                                self.logger.debug(f"Erro ao preparar heartbeat para proposer {proposer_id}: {e}")
                
                # Tempo de espera adaptativo
                sleep_time = self.heartbeat_interval if is_leader else 5
                time.sleep(sleep_time)
                
            except Exception as e:
                self.logger.error(f"Erro na thread de heartbeat: {e}")
                time.sleep(2)  # Em caso de erro, esperar um pouco antes de tentar novamente
    
    def _send_heartbeat(self, url, data):
        """
        Enviar heartbeat para outro proposer
        
        Args:
            url (str): URL do proposer
            data (dict): Dados do heartbeat
        """
        try:
            requests.post(url, json=data, timeout=2)
        except Exception as e:
            self.logger.debug(f"Erro ao enviar heartbeat: {e}")
    
    def _start_election(self, bootstrap=False):
        """
        Iniciar uma eleição para líder
        
        Args:
            bootstrap (bool): Indica se é uma eleição de bootstrap
        """
        with self.lock:
            if self.in_election and not bootstrap:
                return
            
            self.in_election = True
            
            # Em bootstrap, já temos um número de proposta definido
            if not bootstrap:
                # Gerar número de proposta único: timestamp * 100 + ID para garantir unicidade
                current_timestamp = int(time.time())
                self.current_proposal_number = current_timestamp * 100 + self.node_id
                
            self.proposal_accepted_count = 0
            is_bootstrap = "bootstrap " if bootstrap else ""
            self.logger.info(f"Iniciando {is_bootstrap}eleição com proposta número {self.current_proposal_number}")
        
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
            
            # Implementar timeout para a eleição
            election_start_time = time.time()
            election_timeout = self.election_timeout
            
            # Lista para armazenar threads de prepare
            prepare_threads = []
            
            for acceptor_id, acceptor in acceptors.items():
                try:
                    acceptor_url = f"http://{acceptor['address']}:{acceptor['port']}/prepare"
                    data = {
                        "proposer_id": self.node_id,
                        "proposal_number": self.current_proposal_number,
                        "is_leader_election": True
                    }
                    
                    thread = threading.Thread(target=self._send_prepare_with_retry, 
                                             args=(acceptor_url, data, quorum_size, f"leader:{self.node_id}", None, True))
                    prepare_threads.append(thread)
                    thread.start()
                except Exception as e:
                    self.logger.error(f"Erro ao enviar prepare para acceptor {acceptor_id}: {e}")
            
            # Aguardar conclusão das threads ou timeout
            end_time = time.time() + election_timeout
            for thread in prepare_threads:
                timeout = max(0.1, end_time - time.time())
                thread.join(timeout=timeout)
            
            # Verificar se a eleição foi bem-sucedida
            with self.lock:
                if self.in_election:
                    # Se não conseguimos eleger um líder dentro do timeout, abortar a eleição
                    if time.time() > election_start_time + election_timeout:
                        self.logger.warning("Timeout na eleição de líder. Tentando novamente mais tarde.")
                        self.in_election = False
                        # Definir backoff para evitar tempestade de eleições
                        jitter = random.uniform(0.1, 0.5)
                        self.backoff_time = time.time() + random.uniform(2, 5) + jitter
                        
        except Exception as e:
            self.logger.error(f"Erro ao iniciar eleição: {e}")
            with self.lock:
                self.in_election = False
    
    def _send_prepare_with_retry(self, url, data, quorum_size, value, client_id, is_leader_election=False):
        """
        Enviar mensagem prepare com retry para um acceptor
        
        Args:
            url (str): URL do acceptor
            data (dict): Dados para enviar
            quorum_size (int): Tamanho do quórum necessário
            value (str): Valor proposto
            client_id (int): ID do cliente ou None se for eleição
            is_leader_election (bool): Se é uma eleição de líder
        """
        # Implementar retry com backoff exponencial
        max_retries = 3
        base_timeout = 1.0
        
        for retry in range(max_retries):
            try:
                # Backoff exponencial com jitter
                jitter = random.uniform(0.1, 0.3)
                timeout = base_timeout * (2 ** retry) + jitter
                
                response = requests.post(url, json=data, timeout=timeout)
                
                if response.status_code == 200:
                    result = response.json()
                    if result.get("status") == "promise":
                        with self.lock:
                            self.proposal_accepted_count += 1
                            
                            if is_leader_election:
                                self.logger.info(f"Recebido promise para eleição: {self.proposal_accepted_count}/{quorum_size}")
                            else:
                                self.logger.info(f"Recebido promise para valor: {self.proposal_accepted_count}/{quorum_size}")
                            
                            # Se atingir o quórum, enviar accept
                            if self.proposal_accepted_count >= quorum_size:
                                if is_leader_election:
                                    # Eleição de líder bem-sucedida
                                    self.in_election = False
                                    self.logger.info("Quórum atingido! Tornando-se líder")
                                    # Enviar accepts para todos os acceptors
                                    self._send_accept_to_all(value, client_id, is_leader_election)
                                    # Atualizar informação de líder no Gossip
                                    self.gossip.set_leader(self.node_id)
                                    
                                elif self.waiting_for_acceptor_response:
                                    # Proposta normal aceita
                                    self.logger.info("Quórum atingido para proposta! Enviando accepts")
                                    self._send_accept_to_all(value, client_id, is_leader_election)
                                    self.waiting_for_acceptor_response = False
                    else:
                        self.logger.info(f"Acceptor rejeitou prepare: {result.get('message')}")
                        
                        if is_leader_election:
                            # Se for eleição e receber rejeição, verificar se precisamos abortar a eleição
                            # por conflito com outro proposer com número maior
                            if "higher proposal number" in result.get('message', ''):
                                with self.lock:
                                    self.in_election = False
                                    self.logger.warning("Abortando eleição devido a proposta com número maior")
                                    break
                        elif not is_leader_election:
                            # Para proposta normal, se for rejeitado, finalizar
                            with self.lock:
                                if self.waiting_for_acceptor_response:
                                    self.waiting_for_acceptor_response = False
                                    break
                else:
                    self.logger.error(f"Erro ao enviar prepare: {response.status_code} - {response.text}")
                
                # Se obtivemos uma resposta, saímos do retry
                break
            except Exception as e:
                # Última tentativa falhou
                if retry == max_retries - 1:
                    self.logger.error(f"Erro ao enviar prepare após {max_retries} tentativas: {e}")
                    
                    # Finalizar estados pendentes se for a última tentativa
                    if is_leader_election:
                        with self.lock:
                            if self.in_election:
                                self.in_election = False
                    else:
                        with self.lock:
                            if self.waiting_for_acceptor_response:
                                self.waiting_for_acceptor_response = False
                
                # Esperar antes de tentar novamente (exceto na última tentativa)
                if retry < max_retries - 1:
                    time.sleep(base_timeout * (2 ** retry) + jitter)
    
    def _send_accept_to_all(self, value, client_id, is_leader_election):
        """
        Enviar mensagem accept para todos os acceptors
        
        Args:
            value (str): Valor a ser proposto
            client_id (int): ID do cliente ou None se for eleição
            is_leader_election (bool): Se é uma eleição de líder
        """
        try:
            acceptors = self.gossip.get_nodes_by_role('acceptor')
            
            for acceptor_id, acceptor in acceptors.items():
                try:
                    acceptor_url = f"http://{acceptor['address']}:{acceptor['port']}/accept"
                    accept_data = {
                        "proposer_id": self.node_id,
                        "proposal_number": self.current_proposal_number,
                        "is_leader_election": is_leader_election,
                        "value": value,
                        "client_id": client_id
                    }
                    
                    threading.Thread(target=self._send_accept_with_retry, 
                                    args=(acceptor_url, accept_data)).start()
                except Exception as e:
                    self.logger.error(f"Erro ao enviar accept para acceptor {acceptor_id}: {e}")
        except Exception as e:
            self.logger.error(f"Erro ao enviar accepts após quórum: {e}")
    
    def _send_accept_with_retry(self, url, data):
        """
        Enviar mensagem accept com retry para um acceptor
        
        Args:
            url (str): URL do acceptor
            data (dict): Dados para enviar
        """
        # Implementar retry com backoff exponencial
        max_retries = 3
        base_timeout = 1.0
        
        for retry in range(max_retries):
            try:
                # Backoff exponencial com jitter
                jitter = random.uniform(0.1, 0.3)
                timeout = base_timeout * (2 ** retry) + jitter
                
                response = requests.post(url, json=data, timeout=timeout)
                
                if response.status_code == 200:
                    result = response.json()
                    if result.get("status") == "accepted":
                        self.logger.info(f"Accept aceito pelo acceptor")
                    else:
                        self.logger.warning(f"Accept rejeitado: {result.get('message')}")
                else:
                    self.logger.error(f"Erro ao enviar accept: {response.status_code} - {response.text}")
                
                # Se obtivemos uma resposta, saímos do retry
                break
            except Exception as e:
                if retry == max_retries - 1:
                    self.logger.error(f"Erro ao enviar accept após {max_retries} tentativas: {e}")
                else:
                    # Esperar antes de tentar novamente
                    time.sleep(base_timeout * (2 ** retry) + jitter)
    
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
            "bootstrap_mode": self.bootstrap_mode,
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