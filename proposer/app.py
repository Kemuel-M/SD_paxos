import json
import os
import time
import threading
import random
import logging
import requests
from flask import Flask, request, jsonify

# Configuração de logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - [Proposer] - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

app = Flask(__name__)

# Configurações do nó
node_id = int(os.environ.get('NODE_ID', 0))
node_role = os.environ.get('NODE_ROLE', 'proposer')
port = int(os.environ.get('PORT', 3000))
discovery_service = os.environ.get('DISCOVERY_SERVICE', 'http://discovery:7000')

# Estado do nó
is_leader = False
proposal_counter = 0
acceptors = {}
learners = {}
lock = threading.Lock()
current_leader = None
in_election = False
election_timeout = 5  # Timeout para eleição em segundos

# Valores de proposta atual
current_proposal_number = 0
proposed_value = None
proposal_accepted_count = 0
waiting_for_acceptor_response = False

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
    global acceptors, learners
    
    try:
        response = requests.get(f"{discovery_service}/discover")
        if response.status_code == 200:
            nodes = response.json().get("nodes", {})
            
            # Filtrar acceptors e learners
            with lock:
                acceptors = {k: v for k, v in nodes.items() if v.get("role") == "acceptor"}
                learners = {k: v for k, v in nodes.items() if v.get("role") == "learner"}
            
            logger.info(f"Descobertos: {len(acceptors)} acceptors, {len(learners)} learners")
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

def check_leader():
    """Verificar se há um líder ativo e iniciar eleição se necessário"""
    global is_leader, current_leader, in_election
    
    while True:
        try:
            # Verificar líder atual
            response = requests.get(f"{discovery_service}/get-leader")
            if response.status_code == 200:
                leader = response.json().get("leader")
                
                with lock:
                    current_leader = leader
                    # Se não houver líder ou o líder for este nó
                    if leader is None:
                        if not in_election:
                            logger.info("Sem líder detectado, iniciando eleição")
                            start_election()
                    elif int(leader) == node_id:
                        if not is_leader:
                            logger.info("Este nó é o líder!")
                            is_leader = True
                    else:
                        is_leader = False
            else:
                logger.error(f"Erro ao verificar líder: {response.text}")
        except Exception as e:
            logger.error(f"Erro ao verificar líder: {e}")
        
        time.sleep(2)  # Verificar a cada 2 segundos

def start_election():
    """Iniciar uma eleição para líder"""
    global in_election, current_proposal_number, proposal_accepted_count
    
    with lock:
        if in_election:
            return
        
        in_election = True
        # Gerar número de proposta: contador * 100 + ID
        proposal_counter = int(time.time()) % 10000  # Usar timestamp para garantir unicidade
        current_proposal_number = proposal_counter * 100 + node_id
        proposal_accepted_count = 0
    
    logger.info(f"Iniciando eleição com proposta número {current_proposal_number}")
    
    # Enviar mensagem prepare para todos os acceptors
    try:
        discover_nodes()  # Atualizar lista de acceptors
        quorum_size = len(acceptors) // 2 + 1
        
        for acceptor_id, acceptor in acceptors.items():
            try:
                acceptor_url = f"http://{acceptor['address']}:{acceptor['port']}/prepare"
                data = {
                    "proposer_id": node_id,
                    "proposal_number": current_proposal_number,
                    "is_leader_election": True
                }
                
                threading.Thread(target=send_prepare, args=(acceptor_url, data, quorum_size)).start()
            except Exception as e:
                logger.error(f"Erro ao enviar prepare para acceptor {acceptor_id}: {e}")
    except Exception as e:
        logger.error(f"Erro ao iniciar eleição: {e}")
        with lock:
            in_election = False

def send_prepare(url, data, quorum_size):
    """Enviar mensagem prepare para um acceptor"""
    global proposal_accepted_count, is_leader, in_election
    
    try:
        response = requests.post(url, json=data)
        
        if response.status_code == 200:
            result = response.json()
            if result.get("status") == "promise":
                with lock:
                    proposal_accepted_count += 1
                    logger.info(f"Recebido promise: {proposal_accepted_count}/{quorum_size}")
                    
                    # Se atingir o quórum, torna-se líder
                    if proposal_accepted_count >= quorum_size and in_election:
                        is_leader = True
                        in_election = False
                        logger.info("Quórum atingido! Tornando-se líder")
                        
                        # Atualizar serviço de descoberta
                        try:
                            requests.post(f"{discovery_service}/update-leader", json={"leader_id": node_id})
                        except Exception as e:
                            logger.error(f"Erro ao atualizar líder no serviço de descoberta: {e}")
                        
                        # Enviar mensagem accept para todos os acceptors
                        try:
                            for acceptor_id, acceptor in acceptors.items():
                                acceptor_url = f"http://{acceptor['address']}:{acceptor['port']}/accept"
                                accept_data = {
                                    "proposer_id": node_id,
                                    "proposal_number": current_proposal_number,
                                    "is_leader_election": True,
                                    "value": f"leader:{node_id}"
                                }
                                
                                try:
                                    requests.post(acceptor_url, json=accept_data)
                                except Exception as e:
                                    logger.error(f"Erro ao enviar accept para acceptor {acceptor_id}: {e}")
                        except Exception as e:
                            logger.error(f"Erro ao enviar accepts após eleição: {e}")
            else:
                logger.info(f"Acceptor rejeitou proposta: {result.get('message')}")
        else:
            logger.error(f"Erro ao enviar prepare: {response.text}")
    except Exception as e:
        logger.error(f"Erro ao enviar prepare: {e}")

def leader_heartbeat():
    """Enviar heartbeat como líder para os outros nós"""
    while True:
        if is_leader:
            try:
                # Atualizar status de líder no serviço de descoberta
                requests.post(f"{discovery_service}/update-leader", json={"leader_id": node_id})
                logger.info("Enviado heartbeat de líder")
            except Exception as e:
                logger.error(f"Erro ao enviar heartbeat de líder: {e}")
        
        time.sleep(3)  # Enviar a cada 3 segundos

@app.route('/propose', methods=['POST'])
def propose():
    """Receber proposta de um cliente"""
    global proposed_value, current_proposal_number, proposal_accepted_count, waiting_for_acceptor_response
    
    if not is_leader:
        # Redirecionar para o líder atual, se conhecido
        if current_leader:
            try:
                for k, node in requests.get(f"{discovery_service}/discover").json().get("nodes", {}).items():
                    if int(k) == int(current_leader) and node.get("role") == "proposer":
                        leader_url = f"http://{node['address']}:{node['port']}/propose"
                        return requests.post(leader_url, json=request.json).content, 200
            except Exception as e:
                logger.error(f"Erro ao redirecionar para líder: {e}")
        
        return jsonify({"error": "Not the leader", "current_leader": current_leader}), 403
    
    data = request.json
    value = data.get('value')
    client_id = data.get('client_id')
    
    if not value:
        return jsonify({"error": "Value required"}), 400
    
    with lock:
        if waiting_for_acceptor_response:
            return jsonify({"error": "Already processing a proposal"}), 429
        
        waiting_for_acceptor_response = True
        proposed_value = value
        proposal_counter += 1
        current_proposal_number = proposal_counter * 100 + node_id
        proposal_accepted_count = 0
    
    logger.info(f"Recebida proposta do cliente {client_id}: {value}")
    
    # Enviar prepare para todos os acceptors
    try:
        discover_nodes()  # Atualizar lista de acceptors
        quorum_size = len(acceptors) // 2 + 1
        
        for acceptor_id, acceptor in acceptors.items():
            try:
                acceptor_url = f"http://{acceptor['address']}:{acceptor['port']}/prepare"
                prepare_data = {
                    "proposer_id": node_id,
                    "proposal_number": current_proposal_number,
                    "is_leader_election": False
                }
                
                threading.Thread(target=send_client_prepare, args=(
                    acceptor_url, prepare_data, quorum_size, value, client_id)).start()
            except Exception as e:
                logger.error(f"Erro ao enviar prepare para acceptor {acceptor_id}: {e}")
        
        return jsonify({"status": "proposal received", "proposal_number": current_proposal_number}), 200
    except Exception as e:
        logger.error(f"Erro ao processar proposta: {e}")
        with lock:
            waiting_for_acceptor_response = False
        return jsonify({"error": str(e)}), 500

def send_client_prepare(url, data, quorum_size, value, client_id):
    """Enviar mensagem prepare para um acceptor (para proposta de cliente)"""
    global proposal_accepted_count, waiting_for_acceptor_response
    
    try:
        response = requests.post(url, json=data)
        
        if response.status_code == 200:
            result = response.json()
            if result.get("status") == "promise":
                with lock:
                    proposal_accepted_count += 1
                    logger.info(f"Recebido promise para proposta do cliente: {proposal_accepted_count}/{quorum_size}")
                    
                    # Se atingir o quórum, enviar accept
                    if proposal_accepted_count >= quorum_size and waiting_for_acceptor_response:
                        logger.info("Quórum atingido para proposta do cliente! Enviando accepts")
                        
                        # Enviar mensagem accept para todos os acceptors
                        try:
                            for acceptor_id, acceptor in acceptors.items():
                                acceptor_url = f"http://{acceptor['address']}:{acceptor['port']}/accept"
                                accept_data = {
                                    "proposer_id": node_id,
                                    "proposal_number": current_proposal_number,
                                    "is_leader_election": False,
                                    "value": value,
                                    "client_id": client_id
                                }
                                
                                try:
                                    requests.post(acceptor_url, json=accept_data)
                                except Exception as e:
                                    logger.error(f"Erro ao enviar accept para acceptor {acceptor_id}: {e}")
                            
                            # Reiniciar estado
                            waiting_for_acceptor_response = False
                        except Exception as e:
                            logger.error(f"Erro ao enviar accepts após quórum: {e}")
                            waiting_for_acceptor_response = False
            else:
                logger.info(f"Acceptor rejeitou proposta do cliente: {result.get('message')}")
                with lock:
                    # Se algum acceptor rejeitar, precisamos finalizar
                    if waiting_for_acceptor_response:
                        waiting_for_acceptor_response = False
        else:
            logger.error(f"Erro ao enviar prepare para proposta do cliente: {response.text}")
            with lock:
                if waiting_for_acceptor_response:
                    waiting_for_acceptor_response = False
    except Exception as e:
        logger.error(f"Erro ao enviar prepare para proposta do cliente: {e}")
        with lock:
            if waiting_for_acceptor_response:
                waiting_for_acceptor_response = False

@app.route('/health', methods=['GET'])
def health():
    """Verificar saúde do nó"""
    return jsonify({
        "status": "healthy",
        "role": node_role,
        "id": node_id,
        "is_leader": is_leader,
        "current_leader": current_leader
    }), 200

@app.route('/view-logs', methods=['GET'])
def view_logs():
    """Visualizar logs e estado do nó"""
    return jsonify({
        "id": node_id,
        "role": node_role,
        "is_leader": is_leader,
        "current_leader": current_leader,
        "in_election": in_election,
        "proposal_counter": proposal_counter,
        "acceptors_count": len(acceptors),
        "learners_count": len(learners),
        "current_proposal": {
            "number": current_proposal_number,
            "value": proposed_value,
            "accepted_count": proposal_accepted_count,
            "waiting_for_response": waiting_for_acceptor_response
        }
    }), 200

if __name__ == '__main__':
    # Registrar com o serviço de descoberta
    threading.Thread(target=register_with_discovery, daemon=True).start()
    
    # Iniciar thread de heartbeat
    threading.Thread(target=send_heartbeat, daemon=True).start()
    
    # Iniciar thread de verificação de líder
    threading.Thread(target=check_leader, daemon=True).start()
    
    # Iniciar thread de heartbeat de líder
    threading.Thread(target=leader_heartbeat, daemon=True).start()
    
    # Iniciar servidor Flask
    app.run(host='0.0.0.0', port=port)