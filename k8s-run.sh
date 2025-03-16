#!/bin/bash

# Cores para saída
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

clear
echo -e "${BLUE}═════════════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}              SISTEMA PAXOS - INICIALIZAÇÃO DA REDE              ${NC}"
echo -e "${BLUE}═════════════════════════════════════════════════════════════════${NC}"

# Verificar se kubectl está disponível
if ! command -v kubectl &> /dev/null; then
    echo -e "${RED}[ERRO] kubectl não encontrado. Por favor, instale o kubectl antes de continuar.${NC}"
    exit 1
fi

# Verificar se o namespace paxos existe
if ! kubectl get namespace paxos &> /dev/null; then
    echo -e "${RED}[ERRO] Namespace 'paxos' não encontrado. Execute ./deploy-paxos-k8s.sh primeiro.${NC}"
    exit 1
fi

# Verificar se todos os pods estão em execução
echo -e "\n${YELLOW}Verificando status dos pods...${NC}"
PODS_READY=$(kubectl get pods -n paxos -o jsonpath='{.items[*].status.containerStatuses[0].ready}' | tr ' ' '\n' | grep -c "true")
PODS_TOTAL=$(kubectl get pods -n paxos -o jsonpath='{.items[*].status.containerStatuses[0].ready}' | tr ' ' '\n' | wc -l)

if [ "$PODS_READY" -ne "$PODS_TOTAL" ]; then
    echo -e "${YELLOW}Alguns pods ainda não estão prontos ($PODS_READY/$PODS_TOTAL)${NC}"
    echo -e "${YELLOW}Aguardando inicialização de todos os pods...${NC}"
    
    # Esperar até que todos os pods estejam prontos (com timeout)
    timeout=120 # segundos
    elapsed=0
    spinner=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
    spin_idx=0
    
    while [ "$PODS_READY" -ne "$PODS_TOTAL" ] && [ "$elapsed" -lt "$timeout" ]; do
        spin_char="${spinner[spin_idx]}"
        echo -ne "${YELLOW}${spin_char} Aguardando pods... ${elapsed}s/${timeout}s${NC}\r"
        
        spin_idx=$(( (spin_idx + 1) % ${#spinner[@]} ))
        sleep 1
        elapsed=$((elapsed + 1))
        
        PODS_READY=$(kubectl get pods -n paxos -o jsonpath='{.items[*].status.containerStatuses[0].ready}' | tr ' ' '\n' | grep -c "true")
        PODS_TOTAL=$(kubectl get pods -n paxos -o jsonpath='{.items[*].status.containerStatuses[0].ready}' | tr ' ' '\n' | wc -l)
    done
    
    if [ "$PODS_READY" -ne "$PODS_TOTAL" ]; then
        echo -e "\n${RED}[AVISO] Nem todos os pods estão prontos após o timeout.${NC}"
        echo -e "${YELLOW}Continuando, mas podem ocorrer problemas...${NC}"
    else
        echo -e "\n${GREEN}Todos os pods estão prontos!${NC}"
    fi
else
    echo -e "${GREEN}Todos os pods estão prontos ($PODS_READY/$PODS_TOTAL)${NC}"
fi

# Função para verificar a saúde de um serviço
check_service_health() {
    local service=$1
    local namespace=$2
    local result
    
    # Obter o pod correspondente ao serviço
    local pod=$(kubectl get pods -n $namespace -l app=$service -o jsonpath="{.items[0].metadata.name}" 2>/dev/null)
    
    if [ -z "$pod" ]; then
        echo "${RED}Offline${NC} (pod não encontrado)"
        return 1
    fi
    
    # Verificar a saúde do serviço usando o endpoint health
    result=$(kubectl exec -n $namespace $pod -- curl -s http://localhost:8000/health 2>/dev/null)
    
    if [ $? -eq 0 ] && [ -n "$result" ]; then
        echo "${GREEN}Online${NC}"
        return 0
    else
        echo "${RED}Offline${NC}"
        return 1
    fi
}

# Verificar a saúde de todos os serviços
echo -e "\n${BLUE}════════════════════ VERIFICAÇÃO DE SAÚDE ════════════════════${NC}"
printf "${CYAN}%-15s %-15s${NC}\n" "SERVIÇO" "STATUS"
echo -e "${CYAN}───────────────────────────────────────${NC}"

# Verificar proposers
for i in {1..3}; do
    status=$(check_service_health "proposer$i" "paxos")
    printf "%-15s %-15b\n" "Proposer $i" "$status"
done

# Verificar acceptors
for i in {1..3}; do
    status=$(check_service_health "acceptor$i" "paxos")
    printf "%-15s %-15b\n" "Acceptor $i" "$status"
done

# Verificar learners
for i in {1..2}; do
    status=$(check_service_health "learner$i" "paxos")
    printf "%-15s %-15b\n" "Learner $i" "$status"
done

# Verificar clients
for i in {1..2}; do
    status=$(check_service_health "client$i" "paxos")
    printf "%-15s %-15b\n" "Client $i" "$status"
done

# Função para executar comando em um pod
exec_in_pod() {
    local service=$1
    local namespace=$2
    local command=$3
    
    # Obter o pod correspondente ao serviço
    local pod=$(kubectl get pods -n $namespace -l app=$service -o jsonpath="{.items[0].metadata.name}" 2>/dev/null)
    
    if [ -z "$pod" ]; then
        echo "${RED}[ERRO] Pod para $service não encontrado${NC}"
        return 1
    fi
    
    # Executar o comando no pod
    kubectl exec -n $namespace $pod -- bash -c "$command" 2>/dev/null
    return $?
}

# Função para tentar múltiplas vezes iniciar eleição
force_election_with_retry() {
    max_attempts=5
    attempt=1
    success=false
    
    echo -e "${YELLOW}Tentando iniciar eleição de líder (até $max_attempts tentativas)...${NC}"
    
    while [ $attempt -le $max_attempts ] && [ "$success" = false ]; do
        echo -e "${YELLOW}Tentativa $attempt/${max_attempts}...${NC}"
        
        # Tente através de proposer1
        resp1=$(exec_in_pod "proposer1" "paxos" "curl -s -X POST http://localhost:3001/propose -H 'Content-Type: application/json' -d '{\"value\":\"force_election\", \"client_id\":9}'")
        
        # Espere um pouco
        sleep 5
        
        # Verificar se a eleição foi bem-sucedida
        leader=$(exec_in_pod "proposer1" "paxos" "curl -s http://localhost:3001/view-logs | grep -o '\"current_leader\":[^,}]*' | cut -d':' -f2 | tr -d '\"' 2>/dev/null")
        
        if [ -n "$leader" ] && [ "$leader" != "null" ] && [ "$leader" != "None" ]; then
            echo -e "${GREEN}Líder eleito: Proposer $leader${NC}"
            success=true
            break
        fi
        
        # Se falhar com proposer1, tente proposer2
        if [ $attempt -eq 2 ]; then
            echo -e "${YELLOW}Tentando via proposer2...${NC}"
            resp2=$(exec_in_pod "proposer2" "paxos" "curl -s -X POST http://localhost:3002/propose -H 'Content-Type: application/json' -d '{\"value\":\"force_election2\", \"client_id\":9}'")
            sleep 5
        fi
        
        # Se falhar com proposer2, tente proposer3
        if [ $attempt -eq 3 ]; then
            echo -e "${YELLOW}Tentando via proposer3...${NC}"
            resp3=$(exec_in_pod "proposer3" "paxos" "curl -s -X POST http://localhost:3003/propose -H 'Content-Type: application/json' -d '{\"value\":\"force_election3\", \"client_id\":9}'")
            sleep 5
        fi
        
        # Se ainda falhar, tente com Python diretamente
        if [ $attempt -eq 4 ]; then
            echo -e "${YELLOW}Tentando eleição forçada via Python...${NC}"
            python_script=$(cat <<EOF
import json
import time
import requests
import random

def force_election():
    print("Forçando eleição de líder via Python...")
    proposers = [
        ("localhost", 3001),
        ("proposer1", 3001),
        ("proposer2", 3002),
        ("proposer3", 3003)
    ]
    
    # Tentar cada proposer em ordem aleatória
    random.shuffle(proposers)
    
    for proposer, port in proposers:
        try:
            print(f"Tentando via {proposer}:{port}...")
            response = requests.post(
                f"http://{proposer}:{port}/propose",
                json={"value": f"force_election_python_{random.randint(1000,9999)}", "client_id": 9},
                timeout=5
            )
            print(f"Resposta: {response.status_code}")
            if response.status_code == 200:
                print("Requisição aceita!")
            time.sleep(3)
            
            # Verificar se há líder
            status = requests.get(f"http://{proposer}:{port}/view-logs", timeout=2)
            if status.status_code == 200:
                leader = status.json().get('current_leader')
                if leader:
                    print(f"Líder eleito: {leader}")
                    return True
        except Exception as e:
            print(f"Erro: {e}")
    
    return False

force_election()
EOF
)
            exec_in_pod "proposer1" "paxos" "python3 -c \"$python_script\""
            sleep 5
        fi
        
        attempt=$((attempt + 1))
        sleep 2
    done
    
    if [ "$success" = false ]; then
        echo -e "${RED}[AVISO] Não foi possível eleger um líder após $max_attempts tentativas.${NC}"
        echo -e "${YELLOW}O sistema pode não funcionar corretamente até que um líder seja eleito.${NC}"
        return 1
    fi
    
    return 0
}

# Verificar se há um líder eleito e iniciar eleição se necessário
echo -e "\n${YELLOW}Verificando eleição de líder...${NC}"
LEADER_ID=$(exec_in_pod "proposer1" "paxos" "curl -s http://localhost:3001/view-logs | python3 -c \"import sys, json; print(json.load(sys.stdin).get('current_leader', 'None'))\"")

if [ "$LEADER_ID" == "None" ] || [ -z "$LEADER_ID" ] || [ "$LEADER_ID" == "null" ]; then
    echo -e "${YELLOW}Nenhum líder eleito. Forçando eleição...${NC}"
    force_election_with_retry
else
    echo -e "${GREEN}Líder atual: Proposer $LEADER_ID${NC}"
fi

# Obter URLs de acesso
CLIENT_URL=$(minikube service client1-external -n paxos --url | head -n1 2>/dev/null || echo "URL não disponível")
PROPOSER_URL=$(minikube service proposer1-external -n paxos --url | head -n1 2>/dev/null || echo "URL não disponível")

echo -e "\n${GREEN}Sistema Paxos inicializado com sucesso!${NC}"
echo -e "${YELLOW}Para interagir com o sistema, use:${NC}"
echo -e "  ${GREEN}./paxos-client.sh${NC} - Para enviar comandos como cliente"
echo -e "  ${GREEN}./monitor.sh${NC} - Para monitorar o sistema em tempo real"

echo -e "\n${BLUE}═════════════════════ ACESSOS AO SISTEMA ═════════════════════${NC}"
echo -e "${YELLOW}Cliente:${NC} $CLIENT_URL"
echo -e "${YELLOW}Proposer:${NC} $PROPOSER_URL"
echo -e "${YELLOW}Ou use:${NC} minikube service client1-external -n paxos"

echo -e "\n${BLUE}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${YELLOW}Para parar o sistema: ${RED}./cleanup-paxos-k8s.sh${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"