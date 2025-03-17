#!/bin/bash

# Cores para output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

clear
echo -e "${BLUE}═════════════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}        INSTALAÇÃO DO DOCKER E DOCKER COMPOSE PARA SISTEMA PAXOS  ${NC}"
echo -e "${BLUE}═════════════════════════════════════════════════════════════════${NC}"

# Função para verificar se um comando está instalado
command_exists() {
    command -v "$1" &> /dev/null
    return $?
}

# Verificar permissões de sudo
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${YELLOW}Este script precisa ser executado com permissões de superusuário.${NC}"
    echo -e "${YELLOW}Solicitando senha sudo...${NC}"
    if ! sudo -v; then
        echo -e "${RED}Falha ao obter permissões de sudo. Execute o script como superusuário ou use sudo.${NC}"
        exit 1
    fi
fi

# Detectar o sistema operacional
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$NAME
    VER=$VERSION_ID
else
    echo -e "${RED}Não foi possível detectar o sistema operacional.${NC}"
    echo -e "${YELLOW}Este script foi projetado principalmente para Ubuntu/Debian.${NC}"
    OS="Unknown"
fi

echo -e "${YELLOW}Sistema operacional detectado: $OS $VER${NC}"

# Remover versões antigas do Docker, se existirem
echo -e "\n${YELLOW}Verificando e removendo versões antigas do Docker...${NC}"
for pkg in docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc; do
    if dpkg -l | grep -q $pkg; then
        sudo apt-get remove -y $pkg
        echo -e "${GREEN}Removido pacote: $pkg${NC}"
    fi
done

# Atualizar lista de pacotes
echo -e "\n${YELLOW}Atualizando lista de pacotes...${NC}"
sudo apt-get update

# Instalar pacotes necessários para adicionar repositórios
echo -e "\n${YELLOW}Instalando pacotes necessários...${NC}"
sudo apt-get install -y ca-certificates curl gnupg lsb-release apt-transport-https software-properties-common

# Adicionar chave GPG oficial do Docker
echo -e "\n${YELLOW}Adicionando chave GPG oficial do Docker...${NC}"
sudo mkdir -p /etc/apt/keyrings
if [ -f /etc/apt/keyrings/docker.gpg ]; then
    sudo rm /etc/apt/keyrings/docker.gpg
fi

curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg

# Configurar o repositório do Docker
echo -e "\n${YELLOW}Configurando repositório do Docker...${NC}"
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
  $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

# Atualizar lista de pacotes novamente
echo -e "\n${YELLOW}Atualizando lista de pacotes com o novo repositório...${NC}"
sudo apt-get update

# Instalar Docker Engine, containerd e Docker Compose
echo -e "\n${YELLOW}Instalando Docker Engine e Docker Compose...${NC}"
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin docker-compose

# Iniciar e habilitar o serviço Docker
echo -e "\n${YELLOW}Configurando o Docker para iniciar automaticamente...${NC}"
sudo systemctl start docker
sudo systemctl enable docker

# Adicionar o usuário atual ao grupo docker
echo -e "\n${YELLOW}Adicionando o usuário atual ao grupo 'docker'...${NC}"
sudo usermod -aG docker $USER
echo -e "${GREEN}Usuário adicionado ao grupo 'docker'. Pode ser necessário reiniciar a sessão.${NC}"

# Verificar as instalações
echo -e "\n${YELLOW}Verificando instalações...${NC}"

# Verificar Docker
echo -ne "${CYAN}Docker: ${NC}"
if command_exists docker; then
    DOCKER_VERSION=$(docker --version | cut -d ' ' -f3 | tr -d ',')
    echo -e "${GREEN}Instalado (versão $DOCKER_VERSION)${NC}"
else
    echo -e "${RED}Não instalado${NC}"
fi

# Verificar Docker Compose
echo -ne "${CYAN}Docker Compose: ${NC}"
if command_exists docker-compose; then
    COMPOSE_VERSION=$(docker-compose --version | cut -d ' ' -f3 | tr -d ',')
    echo -e "${GREEN}Instalado (versão $COMPOSE_VERSION)${NC}"
else
    echo -e "${RED}Não instalado${NC}"
fi

# Testar o Docker
echo -e "\n${YELLOW}Testando instalação do Docker...${NC}"
if sudo docker run --rm hello-world &> /dev/null; then
    echo -e "${GREEN}Teste bem-sucedido! O Docker está funcionando corretamente.${NC}"
else
    echo -e "${RED}Teste falhou. Pode haver problemas com a instalação do Docker.${NC}"
fi

# Configurações adicionais
echo -e "\n${YELLOW}Configurando ajustes adicionais...${NC}"

# Configurar Docker para usar IPv6
if [ ! -f /etc/docker/daemon.json ]; then
    echo -e "${YELLOW}Configurando suporte a IPv6...${NC}"
    sudo mkdir -p /etc/docker
    echo '{
  "ipv6": true,
  "fixed-cidr-v6": "2001:db8:1::/64"
}' | sudo tee /etc/docker/daemon.json > /dev/null
    sudo systemctl restart docker
    echo -e "${GREEN}Suporte a IPv6 habilitado.${NC}"
fi

# Aumentar limites de recursos para o Docker
if ! grep -q "docker" /etc/security/limits.conf; then
    echo -e "${YELLOW}Configurando limites de recursos para o Docker...${NC}"
    echo "# Limites para usuários do grupo docker
*         soft    nofile      1048576
*         hard    nofile      1048576
root      soft    nofile      1048576
root      hard    nofile      1048576
*         soft    memlock     unlimited
*         hard    memlock     unlimited" | sudo tee -a /etc/security/limits.conf > /dev/null
    echo -e "${GREEN}Limites de recursos configurados.${NC}"
fi

# Resumo e próximos passos
echo -e "\n${BLUE}═════════════════════ RESUMO DE INSTALAÇÃO ═════════════════════${NC}"
echo -e "${GREEN}✓ Docker Engine instalado${NC}"
echo -e "${GREEN}✓ Docker Compose instalado${NC}"
echo -e "${GREEN}✓ Serviço Docker configurado para iniciar automaticamente${NC}"
echo -e "${GREEN}✓ Usuário adicionado ao grupo 'docker'${NC}"
echo -e "${GREEN}✓ Configurações adicionais aplicadas${NC}"

echo -e "\n${BLUE}════════════════════════ PRÓXIMOS PASSOS ════════════════════════${NC}"
echo -e "1. Para aplicar as mudanças do grupo 'docker', faça logout e login novamente ou execute:"
echo -e "   ${CYAN}newgrp docker${NC}"
echo -e "2. Agora você pode implantar o sistema Paxos com:"
echo -e "   ${CYAN}./dk-deploy.sh${NC}"

echo -e "\n${BLUE}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}Instalação do Docker concluída com sucesso!${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"