#!/bin/bash

# Cores para saída
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo -e "${GREEN}Iniciando sistema distribuído Paxos com arquitetura OO e protocolo Gossip...${NC}"

# Verificar se o Docker está instalado
if ! command -v docker &> /dev/null; then
    echo -e "${RED}Docker não encontrado. Por favor, instale o Docker antes de continuar.${NC}"
    exit 1
fi

# Verificar se o modo Swarm está ativo
if ! docker info | grep -q "Swarm: active"; then
    echo -e "${YELLOW}Docker Swarm não está ativo. Inicializando Swarm...${NC}"
    docker swarm init --advertise-addr=$(hostname -I | awk '{print $1}') || {
        echo -e "${RED}Falha ao inicializar Docker Swarm. Verifique sua configuração de rede.${NC}"
        exit 1
    }
fi

# Primeiro, parar qualquer serviço existente
docker stack rm paxos 2>/dev/null
echo -e "${YELLOW}Aguardando limpeza de serviços antigos...${NC}"
sleep 15

# Limpar redes não utilizadas
docker network prune -f

# Construir imagem única
echo -e "${YELLOW}Construindo imagem Docker...${NC}"
# Alterado para usar o Dockerfile no diretório nodes
docker build -t paxos-node -f nodes/Dockerfile . || exit 1

echo -e "${GREEN}Imagem Docker construída com sucesso!${NC}"

# Iniciar o stack
echo -e "${YELLOW}Iniciando serviços...${NC}"
docker stack deploy --compose-file docker-compose.yml paxos || {
    echo -e "${RED}Falha ao iniciar serviços. Verifique seu docker-compose.yml.${NC}"
    exit 1
}

# Aguardar inicialização dos serviços
echo -e "${YELLOW}Aguardando inicialização dos serviços...${NC}"
echo -e "Esta inicialização pode levar mais tempo devido à propagação do Gossip..."
sleep 45  # Tempo aumentado para permitir a propagação do Gossip

# Verificar se todos os serviços estão em execução
services=(
    "paxos_proposer1"
    "paxos_proposer2"
    "paxos_proposer3"
    "paxos_acceptor1"
    "paxos_acceptor2"
    "paxos_acceptor3"
    "paxos_learner1"
    "paxos_learner2"
    "paxos_client1"
    "paxos_client2"
)

for service in "${services[@]}"; do
    replicas=$(docker service ls --filter "name=$service" --format "{{.Replicas}}")
    if [[ ! "$replicas" == "1/1" ]]; then
        echo -e "${RED}Serviço $service não está funcionando corretamente: $replicas. Verificando logs...${NC}"
        docker service logs $service --tail 10
    else
        echo -e "${GREEN}Serviço $service está rodando.${NC}"
    fi
done

echo -e "\n${GREEN}Sistema Paxos inicializado com arquitetura OO e protocolo Gossip!${NC}"
echo -e "${YELLOW}Portas mapeadas:${NC}"
echo -e "Proposers: http://localhost:3001, http://localhost:3002, http://localhost:3003"
echo -e "Acceptors: http://localhost:4001, http://localhost:4002, http://localhost:4003"
echo -e "Learners: http://localhost:5001, http://localhost:5002"
echo -e "Clients: http://localhost:6001, http://localhost:6002"
echo -e "\n${YELLOW}Logs/Monitoramento:${NC}"
echo -e "Proposer1: http://localhost:8001/view-logs"
echo -e "Proposer2: http://localhost:8002/view-logs"
echo -e "Proposer3: http://localhost:8003/view-logs"
echo -e "Acceptor1: http://localhost:8004/view-logs"
echo -e "Acceptor2: http://localhost:8005/view-logs"
echo -e "Acceptor3: http://localhost:8006/view-logs"
echo -e "Learner1: http://localhost:8007/view-logs"
echo -e "Learner2: http://localhost:8008/view-logs"
echo -e "Client1: http://localhost:8009/view-logs"
echo -e "Client2: http://localhost:8010/view-logs"

echo -e "\n${YELLOW}Para interagir com o sistema, acesse as URLs acima${NC}"

echo -e "\n${GREEN}Para parar o sistema: docker stack rm paxos${NC}"