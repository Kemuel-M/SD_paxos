import json
import os
import time
import threading
import logging
import random
import requests
from flask import Flask, request, jsonify

# Importar módulo Gossip
from gossip_protocol import GossipProtocol

class BaseNode:
    """
    Classe base que implementa funcionalidades comuns a todos os tipos de nós
    do sistema Paxos (proposer, acceptor, learner, client).
    Adaptada para ambiente Docker Compose.
    """
    
    def __init__(self, app=None):
        """
        Inicializa o nó base.
        
        Args:
            app (Flask, optional): Aplicação Flask, se não fornecida, uma nova será criada
        """
        # Configuração de logging
        self.node_role = self.__class__.__name__.lower()
        self.logger = logging.getLogger(f'[{self.node_role.capitalize()}]')
        
        # Configurar handler de logging se não existir
        if not self.logger.handlers:
            logging.basicConfig(
                level=logging.INFO,
                format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
            )
        
        # Configurações do nó
        self.node_id = int(os.environ.get('NODE_ID', 0))
        self.port = int(os.environ.get('PORT', self._get_default_port()))
        
        # Definir hostname (ou obter do ambiente)
        self.hostname = os.environ.get('HOSTNAME', 'localhost')
        
        # No Docker Compose, o hostname já é o nome do contêiner
        # Não é necessário processamento adicional como no Kubernetes
        self.logger.info(f"Usando nome do contêiner: {self.hostname}")
        
        # Obter nós sementes (a partir de variáveis de ambiente)
        self.seed_nodes = self._get_seed_nodes()
        
        # Estado comum
        self.lock = threading.Lock()
        
        # Criar ou usar aplicação Flask fornecida
        self.app = app or Flask(__name__)
        
        # Inicializar Gossip
        self.gossip = GossipProtocol(
            self.node_id, 
            self.node_role, 
            self.hostname, 
            self.port, 
            self.seed_nodes
        )
        
        # Registrar rotas comuns
        self._register_common_routes()
    
    def _get_default_port(self):
        """
        Retorna a porta padrão para este tipo de nó.
        Deve ser sobrescrito por classes filhas.
        """
        return 0
    
    def _get_seed_nodes(self):
        """
        Obter nós sementes a partir de variáveis de ambiente.
        Adaptado para ambiente Docker Compose.
        """
        seed_nodes_str = os.environ.get('SEED_NODES', '')
        seed_nodes = []
        
        if seed_nodes_str:
            for node_str in seed_nodes_str.split(','):
                if node_str:
                    parts = node_str.split(':')
                    if len(parts) >= 4:
                        seed_nodes.append({
                            'id': int(parts[0]),
                            'role': parts[1],
                            'address': parts[2],  # No Docker Compose, este é o nome do contêiner
                            'port': int(parts[3])
                        })
        
        return seed_nodes
    
    def _register_common_routes(self):
        """
        Registrar rotas comuns a todos os tipos de nós.
        """
        @self.app.route('/health', methods=['GET'])
        def health():
            """Verificar saúde do nó"""
            # Versão simplificada do health check
            return jsonify({
                "status": "healthy",
                "role": self.node_role,
                "id": self.node_id
            }), 200
        
        @self.app.route('/view-logs', methods=['GET'])
        def view_logs():
            """Visualizar logs e estado do nó"""
            return self._handle_view_logs()
    
    def _handle_view_logs(self):
        """
        Manipulador para a rota view-logs.
        Deve ser implementado pelas classes filhas.
        """
        return jsonify({
            "id": self.node_id,
            "role": self.node_role,
            "known_nodes_count": len(self.gossip.get_all_nodes()),
            "current_leader": self.gossip.get_leader()
        }), 200
    
    def start(self):
        """
        Inicia o nó, incluindo o protocolo Gossip e o servidor Flask.
        """
        # Iniciar protocolo Gossip
        self.gossip.start(self.app)
        
        # Registrar rotas específicas deste tipo de nó
        self._register_routes()
        
        # Iniciar threads específicas
        self._start_threads()
        
        self.logger.info(f"Nó {self.node_role} inicializado com ID {self.node_id}")
        
        # Verificar se gunicorn está disponível
        try:
            import gunicorn
            has_gunicorn = True
        except ImportError:
            has_gunicorn = False
        
        # Se for o proposer1 (líder) e o gunicorn estiver disponível, usar múltiplos workers
        if has_gunicorn and self.node_role == 'proposer' and self.node_id == 1:
            from gunicorn.app.base import BaseApplication
            
            class FlaskApplication(BaseApplication):
                def __init__(self, app, options=None):
                    self.application = app
                    self.options = options or {}
                    super().__init__()
                    
                def load_config(self):
                    for key, value in self.options.items():
                        self.cfg.set(key.lower(), value)
                        
                def load(self):
                    return self.application
            
            gunicorn_options = {
                'bind': '0.0.0.0:' + str(self.port),
                'workers': 4,
                'threads': 2,
                'timeout': 30
            }
            
            FlaskApplication(self.app, gunicorn_options).run()
        else:
            # Iniciar servidor Flask normalmente
            self.app.run(host='0.0.0.0', port=self.port, threaded=True)
    
    def _register_routes(self):
        """
        Registrar rotas específicas para este tipo de nó.
        Deve ser implementado pelas classes filhas.
        """
        pass
    
    def _start_threads(self):
        """
        Iniciar threads específicas para este tipo de nó.
        Deve ser implementado pelas classes filhas.
        """
        pass