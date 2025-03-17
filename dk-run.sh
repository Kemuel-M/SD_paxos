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

# Verificar se o Docker Compose está disponível
if ! command -v docker-compose &> /dev/null; then
    echo -e "${RED}[ERRO] Docker Compose não encontrado. Por favor, instale o Docker Compose antes de continuar.${NC}"
    exit 1
fi

# Verificar se o sistema está em execução
echo -e "\n${YELLOW}Verificando status dos contêineres...${NC}"
if ! docker-compose ps &> /dev/null; then
    echo -e "${RED}[ERRO] Não foi possível verificar o status dos contêineres. Execute ./deploy.sh primeiro.${NC}"
    exit 1
fi

CONTAINERS_UP=$(docker-compose ps | grep "Up" | wc -l)
TOTAL_CONTAINERS=$(docker-compose ps -q | wc -l)

if [ "$CONTAINERS_UP" -ne "$TOTAL_CONTAINERS" ]; then
    echo -e "${YELLOW}Alguns contêineres não estão em execução. Tentando iniciar...${NC}"
    docker-compose up -d
    sleep 5
fi

# Função para verificar a saúde de um serviço
check_service_health() {
    local service=$1
    local port=$2
    local result
    
    # Verificar a saúde do serviço usando o endpoint health
    result=$(curl -s http://localhost:$port/health)
    
    if [ -n "$result" ]; then
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
    port=$((3000 + i))
    monitor_port=$((8000 + i))
    status=$(check_service_health "proposer$i" $port)
    printf "%-15s %-15b\n" "Proposer $i" "$status"
done

# Verificar acceptors
for i in {1..3}; do
    port=$((4000 + i))
    monitor_port=$((8003 + i))
    status=$(check_service_health "acceptor$i" $port)
    printf "%-15s %-15b\n" "Acceptor $i" "$status"
done

# Verificar learners
for i in {1..2}; do
    port=$((5000 + i))
    monitor_port=$((8006 + i))
    status=$(check_service_health "learner$i" $port)
    printf "%-15s %-15b\n" "Learner $i" "$status"
done

# Verificar clients
for i in {1..2}; do
    port=$((6000 + i))
    monitor_port=$((8008 + i))
    status=$(check_service_health "client$i" $port)
    printf "%-15s %-15b\n" "Client $i" "$status"
done

# Função para executar comando em um contêiner
exec_in_container() {
    local container=$1
    local command=$2
    
    docker exec $container bash -c "$command" 2>/dev/null
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
        resp1=$(exec_in_container "proposer1" "curl -s -X POST http://localhost:3001/propose -H 'Content-Type: application/json' -d '{\"value\":\"force_election\", \"client_id\":9}'")
        
        # Espere um pouco
        sleep 5
        
        # Verificar se a eleição foi bem-sucedida
        leader=$(exec_in_container "proposer1" "curl -s http://localhost:3001/view-logs | grep -o '\"current_leader\":[^,}]*' | cut -d':' -f2 | tr -d '\"' 2>/dev/null")
        
        if [ -n "$leader" ] && [ "$leader" != "null" ] && [ "$leader" != "None" ]; then
            echo -e "${GREEN}Líder eleito: Proposer $leader${NC}"
            success=true
            break
        fi
        
        # Se falhar com proposer1, tente proposer2
        if [ $attempt -eq 2 ]; then
            echo -e "${YELLOW}Tentando via proposer2...${NC}"
            resp2=$(exec_in_container "proposer2" "curl -s -X POST http://localhost:3002/propose -H 'Content-Type: application/json' -d '{\"value\":\"force_election2\", \"client_id\":9}'")
            sleep 5
        fi
        
        # Se falhar com proposer2, tente proposer3
        if [ $attempt -eq 3 ]; then
            echo -e "${YELLOW}Tentando via proposer3...${NC}"
            resp3=$(exec_in_container "proposer3" "curl -s -X POST http://localhost:3003/propose -H 'Content-Type: application/json' -d '{\"value\":\"force_election3\", \"client_id\":9}'")
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
            exec_in_container "proposer1" "python3 -c \"$python_script\""
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
LEADER_ID=$(exec_in_container "proposer1" "curl -s http://localhost:3001/view-logs | python3 -c \"import sys, json; print(json.load(sys.stdin).get('current_leader', 'None'))\"")

if [ "$LEADER_ID" == "None" ] || [ -z "$LEADER_ID" ] || [ "$LEADER_ID" == "null" ]; then
    echo -e "${YELLOW}Nenhum líder eleito. Forçando eleição...${NC}"
    force_election_with_retry
else
    echo -e "${GREEN}Líder atual: Proposer $LEADER_ID${NC}"
fi

# Obter URLs de acesso
CLIENT_URL="http://localhost:6001"
PROPOSER_URL="http://localhost:3001"

echo -e "\n${GREEN}Sistema Paxos inicializado com sucesso!${NC}"
echo -e "${YELLOW}Para interagir com o sistema, use:${NC}"
echo -e "  ${GREEN}./client.sh${NC} - Para enviar comandos como cliente"
echo -e "  ${GREEN}./monitor.sh${NC} - Para monitorar o sistema em tempo real"

echo -e "\n${BLUE}═════════════════════ ACESSOS AO SISTEMA ═════════════════════${NC}"
echo -e "${YELLOW}Cliente:${NC} $CLIENT_URL"
echo -e "${YELLOW}Proposer:${NC} $PROPOSER_URL"

echo -e "\n${BLUE}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${YELLOW}Para parar o sistema: ${RED}./cleanup.sh${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"