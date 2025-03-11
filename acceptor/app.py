import json
import os
import time
import threading
import logging
import requests
from flask import Flask, request, jsonify

# Configuração de logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - [Acceptor] - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

app = Flask(__name__)

# Configurações do nó
node_id = int(os.environ.get('NODE_ID', 0))
node_role = os.environ.get('NODE_ROLE', 'acceptor')
port = int(os.environ.get('PORT', 4000))
discovery_service = os.environ.get('DISCOVERY_SERVICE', 'http://discovery:7000')

# Estado do acceptor
highest_promised_number = 0
accepted_proposal_number = 0
accepted_value = None
learners = {}
lock = threading.Lock()

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
    global learners
    
    try:
        response = requests.get(f"{discovery_service}/discover")
        if response.status_code == 200:
            nodes = response.json().get("nodes", {})
            
            # Filtrar learners
            with lock:
                learners = {k: v for k, v in nodes.items() if v.get("role") == "learner"}
            
            logger.info(f"Descobertos: {len(learners)} learners")
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

@app.route('/prepare', methods=['POST'])
def prepare():
    """Receber mensagem prepare de um proposer"""
    global highest_promised_number
    
    data = request.json
    proposer_id = data.get('proposer_id')
    proposal_number = data.get('proposal_number')
    is_leader_election = data.get('is_leader_election', False)
    
    if not all([proposer_id, proposal_number]):
        return jsonify({"error": "Missing required information"}), 400
    
    with lock:
        if proposal_number > highest_promised_number:
            highest_promised_number = proposal_number
            logger.info(f"Prometido para proposta {proposal_number} do proposer {proposer_id}")
            
            return jsonify({
                "status": "promise",
                "accepted_proposal_number": accepted_proposal_number,
                "accepted_value": accepted_value
            }), 200
        else:
            logger.info(f"Rejeitado proposta {proposal_number} do proposer {proposer_id} (prometido: {highest_promised_number})")
            return jsonify({
                "status": "rejected",
                "message": f"Already promised to higher proposal number: {highest_promised_number}"
            }), 200

@app.route('/accept', methods=['POST'])
def accept():
    """Receber mensagem accept de um proposer"""
    global accepted_proposal_number, accepted_value
    
    data = request.json
    proposer_id = data.get('proposer_id')
    proposal_number = data.get('proposal_number')
    value = data.get('value')
    is_leader_election = data.get('is_leader_election', False)
    client_id = data.get('client_id')
    
    if not all([proposer_id, proposal_number, value]):
        return jsonify({"error": "Missing required information"}), 400
    
    with lock:
        if proposal_number >= highest_promised_number:
            accepted_proposal_number = proposal_number
            accepted_value = value
            logger.info(f"Aceitou proposta {proposal_number} com valor: {value}")
            
            # Notificar learners
            threading.Thread(target=notify_learners, args=(proposal_number, value, client_id, is_leader_election)).start()
            
            return jsonify({"status": "accepted"}), 200
        else:
            logger.info(f"Rejeitou proposta {proposal_number} (prometido: {highest_promised_number})")
            return jsonify({
                "status": "rejected",
                "message": f"Already promised to higher proposal number: {highest_promised_number}"
            }), 200

def notify_learners(proposal_number, value, client_id, is_leader_election):
    """Notificar learners sobre valor aceito"""
    # Primeiro, atualizar a lista de learners
    discover_nodes()
    
    logger.info(f"Notificando {len(learners)} learners sobre proposta {proposal_number}")
    
    for learner_id, learner in learners.items():
        try:
            learner_url = f"http://{learner['address']}:{learner['port']}/learn"
            data = {
                "acceptor_id": node_id,
                "proposal_number": proposal_number,
                "value": value,
                "client_id": client_id,
                "is_leader_election": is_leader_election
            }
            
            response = requests.post(learner_url, json=data)
            if response.status_code != 200:
                logger.warning(f"Erro ao notificar learner {learner_id}: {response.text}")
        except Exception as e:
            logger.error(f"Erro ao notificar learner {learner_id}: {e}")

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
        "highest_promised_number": highest_promised_number,
        "accepted_proposal": {
            "number": accepted_proposal_number,
            "value": accepted_value
        },
        "learners_count": len(learners)
    }), 200

if __name__ == '__main__':
    # Registrar com o serviço de descoberta
    threading.Thread(target=register_with_discovery, daemon=True).start()
    
    # Iniciar thread de heartbeat
    threading.Thread(target=send_heartbeat, daemon=True).start()
    
    # Iniciar servidor Flask
    app.run(host='0.0.0.0', port=port)