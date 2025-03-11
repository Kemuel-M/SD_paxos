#!/bin/bash

# Cores para saída
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Função para obter logs de um tipo de nó
get_node_logs() {
    node_type=$1
    port_base=$2
    count=$3
    
    echo -e "${CYAN}=== $node_type Logs ===${NC}"
    
    for i in $(seq 1 $count); do
        port=$((port_base + i - 1))
        url="http://localhost:$port/view-logs"
        
        echo -e "${YELLOW}$node_type $i (porta $port):${NC}"
        curl -s $url | python3 -m json.tool
        echo ""
    done
}

# Monitorar sistema, pressione CTRL+C para sair
echo -e "${GREEN}Monitorando sistema Paxos. Pressione CTRL+C para sair.${NC}"

while true; do
    clear
    echo -e "${GREEN}=== Status do Sistema Paxos ===${NC}"
    echo -e "${YELLOW}$(date)${NC}"
    echo ""
    
    # Discovery Service
    echo -e "${CYAN}=== Discovery Service ===${NC}"
    curl -s http://localhost:8000/view-logs | python3 -m json.tool
    echo ""
    
    # Obter logs dos nós
    get_node_logs "Proposer" 8001 3
    get_node_logs "Acceptor" 8004 3
    get_node_logs "Learner" 8007 2
    get_node_logs "Client" 8009 2
    
    # Status dos serviços Docker
    echo -e "${CYAN}=== Status dos Serviços Docker ===${NC}"
    docker service ls --filter "name=paxos_"
    
    sleep 5
done
