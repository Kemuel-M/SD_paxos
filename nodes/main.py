#!/usr/bin/env python3
import os
import sys
import logging

# Importar classes de nó
from proposer_node import Proposer
from acceptor_node import Acceptor
from learner_node import Learner
from client_node import Client

# Configurar logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger('[Main]')

def main():
    """
    Ponto de entrada principal que inicializa o tipo correto de nó
    com base na variável de ambiente NODE_ROLE.
    """
    # Determinar o tipo de nó a partir da variável de ambiente
    node_role = os.environ.get('NODE_ROLE', '').lower()
    
    # Criar a instância apropriada do nó
    if node_role == 'proposer':
        logger.info("Iniciando nó Proposer")
        node = Proposer()
    elif node_role == 'acceptor':
        logger.info("Iniciando nó Acceptor")
        node = Acceptor()
    elif node_role == 'learner':
        logger.info("Iniciando nó Learner")
        node = Learner()
    elif node_role == 'client':
        logger.info("Iniciando nó Client")
        node = Client()
    else:
        logger.error(f"Tipo de nó desconhecido: {node_role}")
        logger.error("Use NODE_ROLE=proposer|acceptor|learner|client")
        sys.exit(1)
    
    # Iniciar o nó
    node.start()

if __name__ == "__main__":
    main()