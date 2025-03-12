import json
import time
import threading
import logging
import random
import requests
from flask import request, jsonify

class GossipProtocol:
    """
    Implementação do protocolo Gossip para descoberta descentralizada de nós e
    manutenção de estado distribuído em um sistema Paxos.
    """
    
    def __init__(self, node_id, node_role, hostname, port, seed_nodes=None):
        """
        Inicializa o protocolo Gossip.
        
        Args:
            node_id (int): ID único do nó
            node_role (str): Papel do nó (proposer, acceptor, learner, client)
            hostname (str): Nome de host ou endereço IP do nó
            port (int): Porta em que o nó está ouvindo
            seed_nodes (list, optional): Lista de nós sementes para bootstrap inicial
        """
        # Configuração de logging
        self.logger = logging.getLogger(f"[Gossip-{node_role.capitalize()}-{node_id}]")
        
        # Identificação do nó
        self.node_id = node_id
        self.node_role = node_role
        self.hostname = hostname
        self.port = port
        
        # Estado da rede
        self.known_nodes = {}  # {node_id: {id, role, address, port, last_seen, metadata, version}}
        self.leader_id = None
        self.lock = threading.Lock()
        
        # Configurações do protocolo
        self.gossip_interval = 2.0  # segundos
        self.cleanup_interval = 10.0  # segundos
        self.node_timeout = 15.0  # segundos
        self.fanout = 3  # número de nós para enviar em cada rodada
        
        # Mecanismo anti-entropia baseado em versões
        self.self_version = 0  # Versão do estado deste nó
        
        # Adicionar este nó à lista de nós conhecidos
        with self.lock:
            self.known_nodes[str(node_id)] = {
                'id': node_id,
                'role': node_role,
                'address': hostname,
                'port': port,
                'last_seen': time.time(),
                'metadata': {},  # metadados específicos do nó (como status de líder)
                'version': self.self_version
            }
        
        # Adicionar nós sementes (se fornecidos)
        if seed_nodes:
            for node in seed_nodes:
                node_id_str = str(node.get('id'))
                if node_id_str != str(self.node_id):  # Não adicionar a si mesmo
                    with self.lock:
                        self.known_nodes[node_id_str] = {
                            'id': node.get('id'),
                            'role': node.get('role'),
                            'address': node.get('address'),
                            'port': node.get('port'),
                            'last_seen': time.time(),
                            'metadata': node.get('metadata', {}),
                            'version': 0
                        }
                        self.logger.debug(f"Adicionado nó semente: {node_id_str} ({node.get('role')}) em {node.get('address')}:{node.get('port')}")
        
        self.logger.info(f"Protocolo Gossip inicializado. ID: {node_id}, Papel: {node_role}, Endereço: {hostname}:{port}")
    
    def start(self, app):
        """
        Inicia o protocolo Gossip, configurando rotas e threads.
        
        Args:
            app (Flask): Aplicação Flask para registrar rotas
        """
        # Adicionar endpoint para receber informações (push)
        @app.route('/gossip', methods=['POST'])
        def receive_gossip():
            return self._handle_gossip(request.json)
        
        # Adicionar endpoint para consulta de nós
        @app.route('/gossip/nodes', methods=['GET'])
        def get_nodes():
            with self.lock:
                active_nodes = {k: v for k, v in self.known_nodes.items() 
                              if time.time() - v['last_seen'] <= self.node_timeout}
                return jsonify({
                    "total": len(active_nodes),
                    "nodes": active_nodes,
                    "leader_id": self.leader_id
                })
        
        # Iniciar thread para gossip periódico
        threading.Thread(target=self._gossip_loop, daemon=True).start()
        self.logger.debug("Thread de gossip iniciada")
        
        # Iniciar thread para limpeza de nós inativos
        threading.Thread(target=self._cleanup_loop, daemon=True).start()
        self.logger.debug("Thread de limpeza iniciada")
        
        self.logger.info(f"Protocolo Gossip iniciado para {self.node_role} {self.node_id}")
    
    def _gossip_loop(self):
        """Thread que periodicamente envia informações para outros nós."""
        while True:
            try:
                self._send_gossip_to_random_nodes()
            except Exception as e:
                self.logger.error(f"Erro durante gossip: {e}")
            time.sleep(self.gossip_interval)
    
    def _cleanup_loop(self):
        """Thread que periodicamente remove nós inativos."""
        while True:
            try:
                self._remove_inactive_nodes()
            except Exception as e:
                self.logger.error(f"Erro durante limpeza de nós: {e}")
            time.sleep(self.cleanup_interval)
    
    def _send_gossip_to_random_nodes(self):
        """Seleciona nós aleatórios e envia informações atualizadas."""
        # Coletar todos os nós, exceto este nó
        with self.lock:
            other_nodes = {k: v for k, v in self.known_nodes.items() 
                          if k != str(self.node_id) and time.time() - v['last_seen'] <= self.node_timeout}
        
        if not other_nodes:
            self.logger.debug("Nenhum outro nó conhecido para gossip")
            return
        
        # Selecionar fanout nós aleatórios (ou menos se não houver suficientes)
        num_nodes = min(self.fanout, len(other_nodes))
        if num_nodes == 0:
            return
            
        targets = random.sample(list(other_nodes.values()), num_nodes)
        self.logger.debug(f"Selecionados {num_nodes} nós para envio de gossip")
        
        # Preparar dados para envio
        with self.lock:
            # Aumentar a versão deste nó
            self.self_version += 1
            self.known_nodes[str(self.node_id)]['version'] = self.self_version
            self.known_nodes[str(self.node_id)]['last_seen'] = time.time()
            
            gossip_data = {
                "sender_id": self.node_id,
                "sender_role": self.node_role,
                "nodes": self.known_nodes,
                "leader_id": self.leader_id,
                "timestamp": time.time()
            }
        
        # Enviar para cada nó alvo
        for target in targets:
            try:
                target_url = f"http://{target['address']}:{target['port']}/gossip"
                self.logger.debug(f"Enviando gossip para {target['role']} {target['id']} em {target_url}")
                
                response = requests.post(target_url, json=gossip_data, timeout=2.0)
                
                if response.status_code == 200:
                    result = response.json()
                    self.logger.debug(f"Gossip enviado com sucesso para {target['id']}. Atualizações: {result.get('updates', 0)}")
                else:
                    self.logger.warning(f"Falha ao enviar gossip para {target['id']}: {response.text}")
            except Exception as e:
                self.logger.warning(f"Erro ao enviar gossip para {target['id']}: {e}")
    
    def _handle_gossip(self, data):
        """
        Processa informações recebidas de outros nós.
        
        Args:
            data (dict): Dados recebidos de outro nó
        
        Returns:
            Response: Resposta HTTP
        """
        sender_id = data.get("sender_id")
        sender_role = data.get("sender_role")
        received_nodes = data.get("nodes", {})
        received_leader = data.get("leader_id")
        timestamp = data.get("timestamp", time.time())
        
        if not sender_id:
            return jsonify({"status": "error", "message": "Missing sender_id"}), 400
        
        self.logger.debug(f"Recebido gossip de {sender_role} {sender_id} com {len(received_nodes)} nós")
        
        updates = 0
        
        with self.lock:
            # Atualizar informações do remetente
            sender_node = received_nodes.get(str(sender_id), {})
            if sender_node:
                self.known_nodes[str(sender_id)] = {
                    'id': sender_id,
                    'role': sender_role,
                    'address': sender_node.get('address'),
                    'port': sender_node.get('port'),
                    'last_seen': time.time(),
                    'metadata': sender_node.get('metadata', {}),
                    'version': sender_node.get('version', 0)
                }
                self.logger.debug(f"Atualizado remetente: {sender_role} {sender_id}")
            
            # Processar informações sobre outros nós
            for node_id, node_info in received_nodes.items():
                if node_id == str(self.node_id):
                    # Ignorar informações sobre este nó
                    continue
                
                # Verificar se o nó é desconhecido ou se a versão recebida é mais recente
                if (node_id not in self.known_nodes or 
                    node_info.get('version', 0) > self.known_nodes[node_id].get('version', 0)):
                    # Nó desconhecido ou versão mais recente
                    self.known_nodes[node_id] = {
                        'id': node_info.get('id'),
                        'role': node_info.get('role'),
                        'address': node_info.get('address'),
                        'port': node_info.get('port'),
                        'last_seen': timestamp,
                        'metadata': node_info.get('metadata', {}),
                        'version': node_info.get('version', 0)
                    }
                    updates += 1
                    self.logger.debug(f"Atualizado nó: {node_info.get('role')} {node_id} (versão {node_info.get('version', 0)})")
                else:
                    # Mesmo que a versão não seja mais recente, atualizar o last_seen
                    self.known_nodes[node_id]['last_seen'] = max(self.known_nodes[node_id]['last_seen'], timestamp)
            
            # Atualizar informações de líder (se recebido)
            if received_leader and (not self.leader_id or received_leader != self.leader_id):
                old_leader = self.leader_id
                self.leader_id = received_leader
                self.logger.info(f"Líder atualizado: {old_leader} -> {received_leader}")
        
        return jsonify({
            "status": "ok",
            "updates": updates,
            "node_count": len(self.known_nodes)
        }), 200
    
    def _remove_inactive_nodes(self):
        """Remove nós que não enviaram heartbeat por muito tempo."""
        current_time = time.time()
        removed = 0
        
        with self.lock:
            inactive_nodes = [node_id for node_id, node_info in self.known_nodes.items()
                             if (current_time - node_info['last_seen'] > self.node_timeout and
                                 node_id != str(self.node_id))]
            
            for node_id in inactive_nodes:
                if node_id in self.known_nodes:
                    node_info = self.known_nodes[node_id]
                    self.logger.info(f"Removendo nó inativo: {node_id} ({node_info['role']})")
                    del self.known_nodes[node_id]
                    removed += 1
                    
                    # Se o nó removido era o líder, limpar a informação de líder
                    if self.leader_id and str(self.leader_id) == node_id:
                        self.logger.warning(f"Líder {node_id} removido por inatividade")
                        self.leader_id = None
        
        if removed > 0:
            self.logger.info(f"Removidos {removed} nós inativos")
    
    def update_local_metadata(self, metadata_dict):
        """
        Atualiza metadados locais do nó.
        
        Args:
            metadata_dict (dict): Dicionário com metadados para atualizar
        """
        with self.lock:
            node_info = self.known_nodes.get(str(self.node_id))
            if node_info:
                node_info['metadata'].update(metadata_dict)
                self.self_version += 1
                node_info['version'] = self.self_version
                self.logger.debug(f"Metadados locais atualizados: {metadata_dict}, nova versão: {self.self_version}")
    
    def set_leader(self, leader_id):
        """
        Define um novo líder e propaga esta informação.
        
        Args:
            leader_id (int): ID do nó líder
        """
        with self.lock:
            old_leader = self.leader_id
            self.leader_id = leader_id
            
            # Atualizar metadados locais para refletir status de líder
            if leader_id == self.node_id:
                self.update_local_metadata({"is_leader": True})
                self.logger.info(f"Este nó ({self.node_id}) agora é o líder")
            else:
                self.update_local_metadata({"is_leader": False})
                self.logger.info(f"Líder atualizado: {old_leader} -> {leader_id}")
    
    def get_leader(self):
        """
        Obtém o ID do líder atual, se conhecido.
        
        Returns:
            int: ID do líder ou None se não houver líder
        """
        with self.lock:
            return self.leader_id
    
    def get_nodes_by_role(self, role):
        """
        Filtra nós conhecidos pelo papel.
        
        Args:
            role (str): Papel a filtrar (proposer, acceptor, learner, client)
        
        Returns:
            dict: Dicionário de nós filtrados por papel
        """
        with self.lock:
            current_time = time.time()
            result = {k: v for k, v in self.known_nodes.items() 
                    if v['role'] == role and 
                    current_time - v['last_seen'] <= self.node_timeout}
            self.logger.debug(f"Encontrados {len(result)} nós com papel '{role}'")
            return result
    
    def get_all_nodes(self):
        """
        Obtém todos os nós ativos conhecidos.
        
        Returns:
            dict: Dicionário de todos os nós ativos
        """
        with self.lock:
            current_time = time.time()
            result = {k: v for k, v in self.known_nodes.items() 
                    if current_time - v['last_seen'] <= self.node_timeout}
            return result
    
    def get_node_info(self, node_id):
        """
        Obtém informações sobre um nó específico.
        
        Args:
            node_id (int ou str): ID do nó
        
        Returns:
            dict: Informações do nó ou None se não encontrado
        """
        with self.lock:
            return self.known_nodes.get(str(node_id))
    
    def node_exists(self, node_id):
        """
        Verifica se um nó existe e está ativo.
        
        Args:
            node_id (int ou str): ID do nó
        
        Returns:
            bool: True se o nó existe e está ativo, False caso contrário
        """
        with self.lock:
            node = self.known_nodes.get(str(node_id))
            if not node:
                return False
            return time.time() - node['last_seen'] <= self.node_timeout