#!/bin/bash

# Cores para output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

clear
echo -e "${BLUE}═════════════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}              SISTEMA PAXOS - LIMPEZA DOCKER COMPOSE              ${NC}"
echo -e "${BLUE}═════════════════════════════════════════════════════════════════${NC}"

# Verificar se o Docker Compose está disponível
if ! command -v docker-compose &> /dev/null; then
    echo -e "${RED}[ERRO] Docker Compose não encontrado. Por favor, instale o Docker Compose antes de continuar.${NC}"
    exit 1
fi

echo -e "\n${YELLOW}Parando e removendo contêineres...${NC}"

# Verificar se o arquivo docker-compose.yml existe
if [ ! -f "docker-compose.yml" ]; then
    echo -e "${RED}[ERRO] Arquivo docker-compose.yml não encontrado. Verifique se você está no diretório correto.${NC}"
    exit 1
fi

# Parar e remover contêineres
docker-compose down || {
    echo -e "${RED}[ERRO] Falha ao parar os contêineres.${NC}"
    exit 1
}

echo -e "${GREEN}Contêineres parados e removidos com sucesso.${NC}"

# Perguntar se deseja remover as imagens
read -p "Deseja remover as imagens criadas também? (s/n): " REMOVE_IMAGES
if [[ "$REMOVE_IMAGES" == "s" || "$REMOVE_IMAGES" == "S" ]]; then
    echo -e "${YELLOW}Removendo imagens...${NC}"
    docker-compose down --rmi all || {
        echo -e "${RED}[AVISO] Falha ao remover algumas imagens.${NC}"
    }
    echo -e "${GREEN}Imagens removidas.${NC}"
fi

# Perguntar se deseja remover volumes
read -p "Deseja remover volumes? (s/n): " REMOVE_VOLUMES
if [[ "$REMOVE_VOLUMES" == "s" || "$REMOVE_VOLUMES" == "S" ]]; then
    echo -e "${YELLOW}Removendo volumes...${NC}"
    docker-compose down -v || {
        echo -e "${RED}[AVISO] Falha ao remover alguns volumes.${NC}"
    }
    echo -e "${GREEN}Volumes removidos.${NC}"
fi

# Remover arquivos temporários
echo -e "${YELLOW}Limpando arquivos temporários...${NC}"
rm -f *.log *.tmp 2>/dev/null

echo -e "\n${BLUE}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}Sistema Paxos removido com sucesso!${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"