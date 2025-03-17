#!/bin/bash

# Cores para output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

clear
echo -e "${BLUE}═════════════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}              SISTEMA PAXOS - IMPLANTAÇÃO DOCKER COMPOSE          ${NC}"
echo -e "${BLUE}═════════════════════════════════════════════════════════════════${NC}"

echo -e "\n${YELLOW}Verificando pré-requisitos...${NC}"

# Verificar se o Docker está instalado
if ! command -v docker &> /dev/null; then
    echo -e "${RED}[ERRO] Docker não encontrado. Por favor, instale o Docker antes de continuar.${NC}"
    exit 1
fi

# Verificar se o Docker Compose está instalado
if ! command -v docker-compose &> /dev/null; then
    echo -e "${RED}[ERRO] Docker Compose não encontrado. Por favor, instale o Docker Compose antes de continuar.${NC}"
    exit 1
fi

# Verificar se o serviço Docker está em execução
if ! docker info &> /dev/null; then
    echo -e "${YELLOW}Iniciando serviço Docker...${NC}"
    sudo service docker start || {
        echo -e "${RED}[ERRO] Falha ao iniciar o serviço Docker.${NC}"
        exit 1
    }
fi

echo -e "\n${YELLOW}Construindo imagens e iniciando os contêineres...${NC}"
docker-compose build || {
    echo -e "${RED}[ERRO] Falha ao construir as imagens. Verifique se o arquivo docker-compose.yml está correto.${NC}"
    exit 1
}

# Iniciar contêineres em modo detached
echo -e "${YELLOW}Iniciando contêineres em segundo plano...${NC}"
docker-compose up -d || {
    echo -e "${RED}[ERRO] Falha ao iniciar os contêineres.${NC}"
    exit 1
}

# Aguardar a inicialização de todos os contêineres
echo -e "${YELLOW}Aguardando inicialização dos contêineres...${NC}"
echo -e "Esta operação pode levar até 30 segundos..."

# Esperar um pouco para os contêineres inicializarem
sleep 10

# Verificar o status dos contêineres
docker-compose ps

# Função para verificar se todos os contêineres estão prontos
check_containers_ready() {
    local total_containers=$(docker-compose ps -q | wc -l)
    local running_containers=$(docker-compose ps | grep "Up" | wc -l)
    
    if [ "$running_containers" -eq "$total_containers" ] && [ "$total_containers" -gt 0 ]; then
        return 0
    else
        return 1
    fi
}

# Esperar até que todos os contêineres estejam prontos (com timeout)
timeout=30 # segundos
elapsed=0
spinner=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
spin_idx=0

while ! check_containers_ready; do
    spin_char="${spinner[spin_idx]}"
    echo -ne "${YELLOW}${spin_char} Aguardando contêineres... ${elapsed}s/${timeout}s${NC}\r"
    
    spin_idx=$(( (spin_idx + 1) % ${#spinner[@]} ))
    sleep 1
    elapsed=$((elapsed + 1))
    
    if [ "$elapsed" -ge "$timeout" ]; then
        echo -e "\n${RED}[AVISO] Timeout aguardando contêineres. Alguns contêineres podem não estar prontos.${NC}"
        break
    fi
done

if [ "$elapsed" -lt "$timeout" ]; then
    echo -e "\n${GREEN}Todos os contêineres estão prontos!${NC}"
fi

# Obter URLs de acesso
echo -e "\n${BLUE}════════════════════ ACESSOS AO SISTEMA ════════════════════${NC}"
CLIENT_URL="http://localhost:6001"
MONITOR_URL="http://localhost:8009"

echo -e "${GREEN}URL do Cliente: ${CLIENT_URL}${NC}"
echo -e "${GREEN}URL do Monitor: ${MONITOR_URL}${NC}"

echo -e "\n${BLUE}════════════════════ SCRIPTS DISPONÍVEIS ════════════════════${NC}"
echo -e "  ${GREEN}./run.sh${NC} - Iniciar sistema Paxos após a implantação"
echo -e "  ${GREEN}./client.sh${NC} - Cliente interativo"
echo -e "  ${GREEN}./monitor.sh${NC} - Monitorar o sistema em tempo real"
echo -e "  ${GREEN}./cleanup.sh${NC} - Parar e remover os contêineres"

echo -e "\n${BLUE}═══════════════════════════════════════════════════════════════${NC}"
echo -e "Sistema Paxos implantado com sucesso com Docker Compose!"
echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"