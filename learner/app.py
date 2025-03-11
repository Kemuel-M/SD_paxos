import json
import os
import time
import threading
import logging
import requests
from flask import Flask, request, jsonify
from collections import defaultdict

# Configuração de logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - [Learner] - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

app = Flask(__name__)

# Configurações do nó
node_id = int(os.environ.get('NODE_ID', 0))
node_role = os.environ.get('NODE_ROLE', 'learner')
port = int(os.environ.get('PORT', 5000))
discovery_service = os.environ.get('DISCOVERY_SERVICE', 'http://discovery:7000')

# Estado do learner
learned_values = []
proposal_counts = defaultdict(int)
acceptor_responses = defaultdict(dict)
clients = {}
lock = threading.Lock()

# Estado compartilhado entre todos os nós (simulação)
shared_data = []

def register_with_discovery():
    """Registrar este nó com o serviço de descoberta"""
    data = {
        "id": node_id,
        "role": node_role,
        "address": os.environ.get('HOSTNAME', 'localhost'),
        "port": port
    }
    
    try:
        response = requests.post(f"{discovery_service}/register", json=data)
        if response.status_code == 200:
            logger.info("Registrado com sucesso no serviço de descoberta")
            discover_nodes()
        else:
            logger.error(f"Erro ao registrar: {response.text}")
    except Exception as e:
        logger.error(f"Erro ao se conectar com o serviço de descoberta: {e}")

def discover_nodes():
    """Descobrir outros nós na rede"""
    global clients
    
    try:
        response = requests.get(f"{discovery_service}/discover")
        if response.status_code == 200:
            nodes = response.json().get("nodes", {})
            
            # Filtrar clientes
            with lock:
                clients = {k: v for k, v in nodes.items() if v.get("role") == "client"}
            
            logger.info(f"Descobertos: {len(clients)} clientes")
        else:
            logger.error(f"Erro ao descobrir nós: {response.text}")
    except Exception as e:
        logger.error(f"Erro ao descobrir nós: {e}")

def send_heartbeat():
    """Enviar heartbeat para o serviço de descoberta"""
    while True:
        try:
            response = requests.post(f"{discovery_service}/heartbeat", json={"id": node_id})
            if response.status_code != 200:
                logger.warning(f"Erro ao enviar heartbeat: {response.text}")
        except Exception as e:
            logger.error(f"Erro ao enviar heartbeat: {e}")
        
        time.sleep(5)  # Enviar heartbeat a cada 5 segundos

@app.route('/learn', methods=['POST'])
def learn():
    """Receber notificação de valor aceito de um acceptor"""
    global learned_values
    
    data = request.json
    acceptor_id = data.get('acceptor_id')
    proposal_number = data.get('proposal_number')
    value = data.get('value')
    client_id = data.get('client_id')
    is_leader_election = data.get('is_leader_election', False)
    
    if not all([acceptor_id, proposal_number, value]):
        return jsonify({"error": "Missing required information"}), 400
    
    with lock:
        # Registrar resposta deste acceptor
        acceptor_responses[proposal_number][acceptor_id] = value
        
        # Verificar quórum (mais da metade dos acceptors concordam com o mesmo valor)
        discover_nodes()  # Atualizar lista de nós
        response = requests.get(f"{discovery_service}/discover")
        acceptors = {k: v for k, v in response.json().get("nodes", {}).items() if v.get("role") == "acceptor"}
        quorum_size = len(acceptors) // 2 + 1
        
        # Contar quantos acceptors concordam com este valor
        value_count = sum(1 for v in acceptor_responses[proposal_number].values() if v == value)
        
        logger.info(f"Acceptor {acceptor_id} enviou valor: {value} para proposta {proposal_number}. Contagem: {value_count}/{quorum_size}")
        
        if value_count >= quorum_size:
            # Se for uma eleição de líder, não adicionar aos valores aprendidos
            if not is_leader_election:
                # Adicionar aos valores aprendidos
                learned_values.append({"proposal_number": proposal_number, "value": value, "timestamp": time.time()})
                
                # Atualizar dados compartilhados
                if not value.startswith("leader:"):
                    shared_data.append(value)
                
                logger.info(f"Aprendido valor: {value} da proposta {proposal_number}")
                
                # Notificar cliente
                if client_id:
                    threading.Thread(target=notify_client, args=(client_id, value, proposal_number)).start()
    
    return jsonify({"status": "acknowledged"}), 200

def notify_client(client_id, value, proposal_number):
    """Notificar cliente sobre valor aprendido"""
    discover_nodes()  # Atualizar lista de clientes
    
    client = None
    for cid, c in clients.items():
        if str(cid) == str(client_id):
            client = c
            break
    
    if client:
        try:
            client_url = f"http://{client['address']}:{client['port']}/notify"
            data = {
                "learner_id": node_id,
                "proposal_number": proposal_number,
                "value": value,
                "learned_at": time.strftime("%Y-%m-%d %H:%M:%S")
            }
            
            response = requests.post(client_url, json=data)
            if response.status_code != 200:
                logger.warning(f"Erro ao notificar cliente {client_id}: {response.text}")
            else:
                logger.info(f"Cliente {client_id} notificado sobre valor: {value}")
        except Exception as e:
            logger.error(f"Erro ao notificar cliente {client_id}: {e}")
    else:
        logger.warning(f"Cliente {client_id} não encontrado")

@app.route('/get-values', methods=['GET'])
def get_values():
    """Obter valores aprendidos"""
    return jsonify({"values": shared_data}), 200

@app.route('/health', methods=['GET'])
def health():
    """Verificar saúde do nó"""
    return jsonify({
        "status": "healthy",
        "role": node_role,
        "id": node_id
    }), 200

@app.route('/view-logs', methods=['GET'])
def view_logs():
    """Visualizar logs e estado do nó"""
    return jsonify({
        "id": node_id,
        "role": node_role,
        "learned_values_count": len(learned_values),
        "recent_learned_values": learned_values[-10:] if learned_values else [],
        "shared_data": shared_data,
        "clients_count": len(clients)
    }), 200

if __name__ == '__main__':
    # Registrar com o serviço de descoberta
    threading.Thread(target=register_with_discovery, daemon=True).start()
    
    # Iniciar thread de heartbeat
    threading.Thread(target=send_heartbeat, daemon=True).start()
    
    # Iniciar servidor Flask
    app.run(host='0.0.0.0', port=port)