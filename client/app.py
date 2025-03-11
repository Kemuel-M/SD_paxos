import json
import os
import time
import threading
import logging
import requests
from flask import Flask, request, jsonify
import random

# Configuração de logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - [Client] - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

app = Flask(__name__)

# Configurações do nó
node_id = int(os.environ.get('NODE_ID', 0))
node_role = os.environ.get('NODE_ROLE', 'client')
port = int(os.environ.get('PORT', 6000))
discovery_service = os.environ.get('DISCOVERY_SERVICE', 'http://discovery:7000')

# Estado do cliente
proposers = {}
responses = []
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
    global proposers
    
    try:
        response = requests.get(f"{discovery_service}/discover")
        if response.status_code == 200:
            nodes = response.json().get("nodes", {})
            
            # Filtrar proposers
            with lock:
                proposers = {k: v for k, v in nodes.items() if v.get("role") == "proposer"}
            
            logger.info(f"Descobertos: {len(proposers)} proposers")
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

@app.route('/send', methods=['POST'])
def send():
    """Enviar valor para o sistema Paxos"""
    data = request.json
    value = data.get('value')
    
    if not value:
        return jsonify({"error": "Value required"}), 400
    
    # Descobrir proposers
    discover_nodes()
    
    if not proposers:
        return jsonify({"error": "No proposers available"}), 503
    
    # Obter líder atual
    leader_id = None
    try:
        response = requests.get(f"{discovery_service}/get-leader")
        if response.status_code == 200:
            leader_id = response.json().get("leader")
    except Exception as e:
        logger.error(f"Erro ao obter líder: {e}")
    
    # Enviar para o líder, se conhecido, ou para um proposer aleatório
    target_proposer = None
    if leader_id and str(leader_id) in proposers:
        target_proposer = proposers[str(leader_id)]
    else:
        # Escolher um proposer aleatório
        proposer_id = random.choice(list(proposers.keys()))
        target_proposer = proposers[proposer_id]
    
    try:
        proposer_url = f"http://{target_proposer['address']}:{target_proposer['port']}/propose"
        data = {
            "value": value,
            "client_id": node_id
        }
        
        response = requests.post(proposer_url, json=data)
        
        if response.status_code == 200:
            logger.info(f"Valor '{value}' enviado para proposer {target_proposer['id']}")
            return jsonify({"status": "value sent", "proposer_id": target_proposer['id']}), 200
        elif response.status_code == 403:
            # Não é o líder, tente o líder sugerido
            result = response.json()
            new_leader = result.get("current_leader")
            
            if new_leader and str(new_leader) in proposers:
                new_target = proposers[str(new_leader)]
                proposer_url = f"http://{new_target['address']}:{new_target['port']}/propose"
                
                response = requests.post(proposer_url, json=data)
                
                if response.status_code == 200:
                    logger.info(f"Valor '{value}' enviado para líder {new_target['id']}")
                    return jsonify({"status": "value sent", "proposer_id": new_target['id']}), 200
                else:
                    return jsonify({"error": f"Error sending to leader: {response.text}"}), 500
            else:
                return jsonify({"error": "Leader not available"}), 503
        else:
            return jsonify({"error": f"Error sending to proposer: {response.text}"}), 500
    except Exception as e:
        logger.error(f"Erro ao enviar para proposer: {e}")
        return jsonify({"error": str(e)}), 500

@app.route('/notify', methods=['POST'])
def notify():
    """Receber notificação de learner sobre valor aprendido"""
    global responses
    
    data = request.json
    learner_id = data.get('learner_id')
    proposal_number = data.get('proposal_number')
    value = data.get('value')
    learned_at = data.get('learned_at')
    
    if not all([learner_id, proposal_number, value]):
        return jsonify({"error": "Missing required information"}), 400
    
    with lock:
        responses.append({
            "learner_id": learner_id,
            "proposal_number": proposal_number,
            "value": value,
            "learned_at": learned_at,
            "received_at": time.strftime("%Y-%m-%d %H:%M:%S")
        })
    
    logger.info(f"Notificação recebida do learner {learner_id}: valor '{value}' foi aprendido")
    return jsonify({"status": "acknowledged"}), 200

@app.route('/read', methods=['GET'])
def read():
    """Ler valores aprendidos"""
    # Encontrar learners
    response = requests.get(f"{discovery_service}/discover")
    learners = {k: v for k, v in response.json().get("nodes", {}).items() if v.get("role") == "learner"}
    
    if not learners:
        return jsonify({"error": "No learners available"}), 503
    
    # Escolher um learner aleatório
    learner_id = random.choice(list(learners.keys()))
    learner = learners[learner_id]
    
    try:
        learner_url = f"http://{learner['address']}:{learner['port']}/get-values"
        response = requests.get(learner_url)
        
        if response.status_code == 200:
            values = response.json().get("values", [])
            logger.info(f"Leitura concluída: {len(values)} valores obtidos do learner {learner_id}")
            return jsonify({"values": values}), 200
        else:
            return jsonify({"error": f"Error reading from learner: {response.text}"}), 500
    except Exception as e:
        logger.error(f"Erro ao ler do learner: {e}")
        return jsonify({"error": str(e)}), 500

@app.route('/get-responses', methods=['GET'])
def get_responses():
    """Obter respostas recebidas"""
    with lock:
        return jsonify({"responses": responses}), 200

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
        "proposers_count": len(proposers),
        "responses_count": len(responses),
        "recent_responses": responses[-10:] if responses else []
    }), 200

if __name__ == '__main__':
    # Registrar com o serviço de descoberta
    threading.Thread(target=register_with_discovery, daemon=True).start()
    
    # Iniciar thread de heartbeat
    threading.Thread(target=send_heartbeat, daemon=True).start()
    
    # Iniciar servidor Flask
    app.run(host='0.0.0.0', port=port)