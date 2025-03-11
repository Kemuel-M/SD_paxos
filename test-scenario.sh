#!/bin/bash

# Cores para saída
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

echo -e "${GREEN}Executando cenário de teste para o sistema Paxos...${NC}"

# Verificar se o sistema está rodando
if ! docker service ls | grep -q "paxos_"; then
    echo -e "${RED}Sistema Paxos não está em execução. Execute ./run.sh primeiro.${NC}"
    exit 1
fi

# Aguardar inicialização completa
echo -e "${YELLOW}Aguardando inicialização completa dos serviços...${NC}"
sleep 5

# Função para escrita
write_value() {
    client=$1
    value=$2
    
    echo -e "${CYAN}Cliente $client escrevendo: \"$value\"${NC}"
    ./client/client_cli.py localhost $client write "$value"
    echo ""
    sleep 2
}

# Função para leitura
read_values() {
    client=$1
    
    echo -e "${CYAN}Cliente $client lendo valores:${NC}"
    ./client/client_cli.py localhost $client read
    echo ""
    sleep 2
}

# Função para visualizar respostas
view_responses() {
    client=$1
    
    echo -e "${CYAN}Respostas recebidas pelo Cliente $client:${NC}"
    ./client/client_cli.py localhost $client responses
    echo ""
    sleep 2
}

# Verificar líder atual
echo -e "${YELLOW}Verificando líder atual...${NC}"
leader=$(curl -s http://localhost:7000/get-leader | python -m json.tool)
echo -e "${GREEN}Líder atual: $leader${NC}"
echo ""

# Teste 1: Escrita de valores simples com o Cliente 1
echo -e "${YELLOW}Teste 1: Escrita de valores simples com o Cliente 1${NC}"
write_value 6001 "Valor de teste 1"
write_value 6001 "Valor de teste 2"
write_value 6001 "Valor de teste 3"

# Verificar respostas do Cliente 1
view_responses 6001

# Teste 2: Leitura de valores com o Cliente 2
echo -e "${YELLOW}Teste 2: Leitura de valores com o Cliente 2${NC}"
read_values 6002

# Teste 3: Escrita de valores com o Cliente 2
echo -e "${YELLOW}Teste 3: Escrita de valores com o Cliente 2${NC}"
write_value 6002 "Valor do cliente 2"
write_value 6002 "Outro valor do cliente 2"

# Verificar respostas do Cliente 2
view_responses 6002

# Teste 4: Leitura com ambos os clientes
echo -e "${YELLOW}Teste 4: Leitura com ambos os clientes${NC}"
read_values 6001
read_values 6002

# Teste 5: Simular falha de um nó (opcional)
echo -e "${YELLOW}Teste 5: Simular falha de um proposer (opcional)${NC}"
read -p "Deseja simular a falha de um proposer? (s/n): " simulate_failure

if [[ $simulate_failure == "s" ]]; then
    # Obter o ID do contêiner do proposer1
    container_id=$(docker ps | grep paxos_proposer1 | awk '{print $1}')
    
    if [[ -n $container_id ]]; then
        echo -e "${RED}Parando proposer1 (container $container_id)...${NC}"
        docker stop $container_id
        
        echo -e "${YELLOW}Aguardando recuperação do sistema...${NC}"
        sleep 10
        
        # Verificar novo líder
        new_leader=$(curl -s http://localhost:7000/get-leader | python -m json.tool)
        echo -e "${GREEN}Novo líder após falha: $new_leader${NC}"
        
        # Tentar escrever com o Cliente 1
        write_value 6001 "Valor após falha do proposer"
        
        # Verificar se o valor foi recebido
        view_responses 6001
        
        # Reiniciar o contêiner
        echo -e "${YELLOW}Reiniciando proposer1...${NC}"
        docker start $container_id
    else
        echo -e "${RED}Não foi possível encontrar o contêiner do proposer1.${NC}"
    fi
fi

echo -e "${GREEN}Cenário de teste concluído!${NC}"
