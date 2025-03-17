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
    local timeout=$3
    
    if [ -z "$timeout" ]; then
        timeout=5
    fi
    
    docker exec $container timeout $timeout bash -c "$command" 2>/dev/null
    return $?
}

# Função para tentar eleição de líder com timeout
force_election_with_timeout() {
    local attempt=$1
    local proposer=$2
    local port=$3
    
    echo -e "${YELLOW}Tentativa $attempt: Via $proposer (porta $port)${NC}"
    
    # Usar timeout para não ficar preso
    response=$(docker exec $proposer timeout 3 curl -s -X POST "http://localhost:$port/propose" \
        -H 'Content-Type: application/json' \
        -d "{\"value\":\"force_election_$attempt\", \"client_id\":9, \"is_leader_election\":true}")
    
    echo -e "${CYAN}Resposta: ${response:0:100}${NC}"  # Mostrar parte inicial da resposta
    
    # Esperar um pouco para permitir que a eleição seja processada
    sleep 2
    
    # Verificar se lider foi eleito
    leader=$(docker exec $proposer timeout 2 curl -s "http://localhost:$port/view-logs" | grep -o '"current_leader":[^,}]*' | cut -d':' -f2 | tr -d '\"' 2>/dev/null)
    
    # Se líder não for null ou vazio, retornar sucesso
    if [ ! -z "$leader" ] && [ "$leader" != "null" ] && [ "$leader" != "None" ] && [ "$leader" != "\"None\"" ]; then
        echo -e "${GREEN}Líder eleito: Proposer $leader${NC}"
        return 0
    fi
    
    return 1
}

# Função para tentar força com timeout
try_python_election_with_timeout() {
    echo -e "${YELLOW}Tentando eleição forçada via Python...${NC}"
    
    # Script Python direto e simples para tentar eleição
    python_script=$(cat <<EOF
import json
import time
import requests
import random

# Tentar cada proposer
proposers = [
    ("localhost", 3001),
    ("localhost", 3002),
    ("localhost", 3003)
]

# Tentar cada um em ordem
for proposer, port in proposers:
    print(f"Tentando eleição via {proposer}:{port}")
    try:
        data = {
            "value": f"force_election_python_{random.randint(1000,9999)}", 
            "client_id": 9,
            "is_leader_election": True
        }
        
        # Timeout curto para não ficar preso
        response = requests.post(
            f"http://{proposer}:{port}/propose",
            json=data,
            timeout=3
        )
        print(f"Status: {response.status_code}")
        
        # Verificar se há sucesso
        if response.status_code == 200:
            print("Requisição de eleição enviada com sucesso")
            # Esperar um pouco
            time.sleep(2)
            
            # Verificar se líder foi eleito
            try:
                status = requests.get(f"http://{proposer}:{port}/view-logs", timeout=2)
                if status.status_code == 200:
                    leader = status.json().get('current_leader')
                    if leader:
                        print(f"Líder eleito: {leader}")
                        exit(0)  # Sucesso
            except Exception as e:
                print(f"Erro ao verificar líder: {e}")
    except Exception as e:
        print(f"Erro: {e}")

print("Não conseguiu eleger um líder via Python")
exit(1)  # Falha
EOF
)

    # Executar o script em qualquer proposer com timeout
    timeout 10 docker exec proposer1 python3 -c "$python_script"
    return $?
}

# Verificar se há um líder eleito e iniciar eleição se necessário
echo -e "\n${YELLOW}Verificando eleição de líder...${NC}"
LEADER_ID=$(docker exec proposer1 timeout 3 curl -s http://localhost:3001/view-logs | grep -o '"current_leader":[^,}]*' | cut -d':' -f2 | tr -d '\"' 2>/dev/null)

if [ -z "$LEADER_ID" ] || [ "$LEADER_ID" == "null" ] || [ "$LEADER_ID" == "None" ] || [ "$LEADER_ID" == "\"None\"" ]; then
    echo -e "${YELLOW}Nenhum líder eleito. Forçando eleição...${NC}"
    
    # Tentar forçar eleição com timeout para cada proposer
    MAX_ATTEMPTS=5
    
    echo -e "${YELLOW}Tentando iniciar eleição de líder (até $MAX_ATTEMPTS tentativas)...${NC}"
    
    # Tentativa 1 - proposer1
    if force_election_with_timeout 1 "proposer1" 3001; then
        ELECTION_SUCCESS=true
    # Tentativa 2 - proposer2
    elif force_election_with_timeout 2 "proposer2" 3002; then
        ELECTION_SUCCESS=true
    # Tentativa 3 - proposer3
    elif force_election_with_timeout 3 "proposer3" 3003; then
        ELECTION_SUCCESS=true
    # Tentativa 4 - script Python
    elif try_python_election_with_timeout; then
        ELECTION_SUCCESS=true
    # Tentativa 5 - cliente
    else
        echo -e "${YELLOW}Tentativa 5: Via client1${NC}"
        docker exec client1 timeout 3 curl -s -X POST "http://localhost:6001/send" -H 'Content-Type: application/json' -d '{"value":"force_election_final"}'
        sleep 3
        
        # Verificar uma última vez
        LEADER_ID=$(docker exec proposer1 timeout 2 curl -s http://localhost:3001/view-logs | grep -o '"current_leader":[^,}]*' | cut -d':' -f2 | tr -d '\"' 2>/dev/null)
        
        if [ ! -z "$LEADER_ID" ] && [ "$LEADER_ID" != "null" ] && [ "$LEADER_ID" != "None" ] && [ "$LEADER_ID" != "\"None\"" ]; then
            echo -e "${GREEN}Líder eleito na última tentativa: Proposer $LEADER_ID${NC}"
            ELECTION_SUCCESS=true
        else
            ELECTION_SUCCESS=false
            echo -e "${RED}[AVISO] Não foi possível eleger um líder após várias tentativas.${NC}"
            echo -e "${YELLOW}O sistema pode funcionar mesmo sem um líder eleito, mas com performance reduzida.${NC}"
        fi
    fi
else
    echo -e "${GREEN}Líder atual: Proposer $LEADER_ID${NC}"
    ELECTION_SUCCESS=true
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