import json
import os
import time
import threading
import logging
from flask import Flask, request, jsonify

# Configuração de logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - [Discovery] - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

app = Flask(__name__)

# Armazenamento de nós registrados
nodes = {}
leader = None
lock = threading.Lock()

@app.route('/register', methods=['POST'])
def register():
    """Registrar um novo nó na rede"""
    data = request.json
    node_id = data.get('id')
    role = data.get('role')
    address = data.get('address')
    port = data.get('port')
    
    if not all([node_id, role, address, port]):
        return jsonify({"error": "Missing required information"}), 400
    
    with lock:
        nodes[node_id] = {
            "id": node_id,
            "role": role,
            "address": address,
            "port": port,
            "last_heartbeat": time.time()
        }
    
    logger.info(f"Nó registrado: ID={node_id}, Papel={role}, Endereço={address}:{port}")
    return jsonify({"status": "registered", "nodes": nodes}), 200

@app.route('/discover', methods=['GET'])
def discover():
    """Obter lista de todos os nós ativos na rede"""
    return jsonify({"nodes": nodes}), 200

@app.route('/heartbeat', methods=['POST'])
def heartbeat():
    """Receber heartbeat de um nó"""
    data = request.json
    node_id = data.get('id')
    
    if not node_id or node_id not in nodes:
        return jsonify({"error": "Node not registered"}), 404
    
    with lock:
        nodes[node_id]["last_heartbeat"] = time.time()
    
    return jsonify({"status": "heartbeat received"}), 200

@app.route('/deregister', methods=['POST'])
def deregister():
    """Desregistrar um nó que está saindo da rede"""
    data = request.json
    node_id = data.get('id')
    
    if not node_id:
        return jsonify({"error": "Node ID required"}), 400
    
    with lock:
        if node_id in nodes:
            del nodes[node_id]
            logger.info(f"Nó desregistrado: ID={node_id}")
            return jsonify({"status": "deregistered"}), 200
        else:
            return jsonify({"error": "Node not found"}), 404

@app.route('/update-leader', methods=['POST'])
def update_leader():
    """Atualizar o líder atual"""
    global leader
    data = request.json
    leader_id = data.get('leader_id')
    
    if not leader_id:
        return jsonify({"error": "Leader ID required"}), 400
    
    with lock:
        leader = leader_id
        logger.info(f"Novo líder: ID={leader_id}")
    
    return jsonify({"status": "leader updated", "leader": leader}), 200

@app.route('/get-leader', methods=['GET'])
def get_leader():
    """Obter o ID do líder atual"""
    return jsonify({"leader": leader}), 200

@app.route('/health', methods=['GET'])
def health():
    """Verificar saúde do serviço de descoberta"""
    return jsonify({"status": "healthy"}), 200

@app.route('/view-logs', methods=['GET'])
def view_logs():
    """Visualizar logs do serviço de descoberta"""
    active_nodes = 0
    proposers = 0
    acceptors = 0
    learners = 0
    clients = 0

    # Filtrar nós ativos (heartbeat nos últimos 10 segundos)
    current_time = time.time()
    with lock:
        for node in nodes.values():
            if current_time - node["last_heartbeat"] < 10:
                active_nodes += 1
                if node["role"] == "proposer":
                    proposers += 1
                elif node["role"] == "acceptor":
                    acceptors += 1
                elif node["role"] == "learner":
                    learners += 1
                elif node["role"] == "client":
                    clients += 1

    return jsonify({
        "active_nodes": active_nodes,
        "proposers": proposers,
        "acceptors": acceptors,
        "learners": learners,
        "clients": clients,
        "current_leader": leader,
        "nodes": nodes
    }), 200

def cleanup_inactive_nodes():
    """Função periódica para remover nós inativos"""
    while True:
        time.sleep(10)  # Verificar a cada 10 segundos
        current_time = time.time()
        with lock:
            inactive_nodes = []
            for node_id, node in list(nodes.items()):
                # Se o último heartbeat for mais antigo que 30 segundos, o nó é considerado inativo
                if current_time - node["last_heartbeat"] > 30:
                    inactive_nodes.append(node_id)
            
            for node_id in inactive_nodes:
                del nodes[node_id]
                logger.info(f"Nó removido por inatividade: ID={node_id}")

if __name__ == '__main__':
    # Iniciar thread de limpeza
    cleanup_thread = threading.Thread(target=cleanup_inactive_nodes, daemon=True)
    cleanup_thread.start()
    
    # Iniciar servidor Flask
    port = int(os.environ.get('PORT', 7000))
    app.run(host='0.0.0.0', port=port)