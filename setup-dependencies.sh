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
echo -e "${BLUE}        INSTALAÇÃO DE DEPENDÊNCIAS PARA SISTEMA PAXOS            ${NC}"
echo -e "${BLUE}═════════════════════════════════════════════════════════════════${NC}"

# Verificar permissões de sudo
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${YELLOW}Este script precisa ser executado com permissões de superusuário.${NC}"
    echo -e "${YELLOW}Solicitando senha sudo...${NC}"
    if ! sudo -v; then
        echo -e "${RED}Falha ao obter permissões de sudo. Execute o script como superusuário ou use sudo.${NC}"
        exit 1
    fi
fi

# Função para verificar se um comando está instalado
command_exists() {
    command -v "$1" &> /dev/null
    return $?
}

# Função para verificar status de um pacote
check_package() {
    local package=$1
    if command_exists $package; then
        echo -e "${GREEN}$package ✓${NC}"
        return 0
    else
        echo -e "${RED}$package ✗${NC}"
        return 1
    fi
}

# Função para instalar um pacote
install_package() {
    local package=$1
    echo -e "${YELLOW}Instalando $package...${NC}"
    
    # Verificar se o pacote já está instalado na versão mais recente
    if apt-cache policy $package | grep -q "Installed: $(apt-cache policy $package | grep "Candidate:" | awk '{print $2}')"; then
        echo -e "${GREEN}$package já está na versão mais recente!${NC}"
        return 0
    fi
    
    # Instalar o pacote
    sudo apt-get install -y $package
    
    # Verificar se a instalação foi bem-sucedida
    if command_exists $package || dpkg -l | grep -q "ii  $package "; then
        echo -e "${GREEN}$package instalado com sucesso!${NC}"
        return 0
    else
        echo -e "${RED}Falha ao instalar $package. Verifique os logs acima.${NC}"
        return 1
    fi
}

# Atualizar lista de pacotes
echo -e "${YELLOW}Atualizando lista de pacotes...${NC}"
sudo apt-get update

# Instalar dependências essenciais
echo -e "\n${YELLOW}Instalando dependências essenciais...${NC}"
sudo apt-get install -y apt-transport-https ca-certificates curl software-properties-common gnupg2

# Instalar ferramentas de processamento
echo -e "\n${YELLOW}Instalando ferramentas de processamento (jq, curl)...${NC}"
install_package "jq"
install_package "curl"

# Instalar utilitários de rede
echo -e "\n${YELLOW}Instalando utilitários de rede...${NC}"
install_package "net-tools"
install_package "dnsutils"
install_package "iputils-ping"
install_package "socat"  # Necessário para port-forward

# Instalar Python e pacotes necessários
echo -e "\n${YELLOW}Instalando Python e pacotes necessários...${NC}"
install_package "python3"
install_package "python3-pip"
install_package "python3-venv"

# Limpar qualquer ambiente virtual anterior que possa estar corrompido
echo -e "${YELLOW}Verificando ambiente virtual existente...${NC}"
if [ -d "venv" ]; then
    echo -e "${YELLOW}Removendo ambiente virtual anterior...${NC}"
    rm -rf venv
fi

# Criar ambiente virtual para o Paxos usando python3-venv
echo -e "${YELLOW}Criando novo ambiente virtual Python para o sistema Paxos...${NC}"
python3 -m venv venv
echo -e "${GREEN}Ambiente virtual criado em ./venv/${NC}"

# Atualizar pip dentro do ambiente virtual
echo -e "${YELLOW}Atualizando pip no ambiente virtual...${NC}"
./venv/bin/python -m ensurepip --upgrade || {
    echo -e "${RED}Falha ao inicializar pip no ambiente virtual. Tentando método alternativo...${NC}"
    curl https://bootstrap.pypa.io/get-pip.py -o get-pip.py
    ./venv/bin/python get-pip.py
    rm -f get-pip.py
}

# Instalar pacotes no ambiente virtual
echo -e "${YELLOW}Instalando pacotes Python no ambiente virtual...${NC}"
./venv/bin/pip install --upgrade pip
./venv/bin/pip install requests flask werkzeug
echo -e "${GREEN}Pacotes Python instalados no ambiente virtual!${NC}"

# Resumo de instalação
echo -e "\n${BLUE}═════════════════════ RESUMO DE INSTALAÇÃO ═════════════════════${NC}"
echo -ne "Ferramentas de processamento: "
check_package jq
echo -ne ", "
check_package curl

echo -ne "\nUtilitários de rede: "
check_package ping
echo -ne ", "
check_package netstat
echo -ne ", "
check_package nslookup
echo -ne ", "
check_package socat

echo -ne "\nProgramação: "
check_package python3
echo -ne ", "
check_package pip3

# Verificar ambiente virtual
if [ -f "venv/bin/python" ] && [ -f "venv/bin/pip" ]; then
    echo -e "\nAmbiente virtual Python: ${GREEN}Configurado ✓${NC}"
else
    echo -e "\nAmbiente virtual Python: ${RED}Não configurado ✗${NC}"
fi

# Próximos passos
echo -e "\n${BLUE}════════════════════════ PRÓXIMOS PASSOS ════════════════════════${NC}"
echo -e "1. Execute o script para configurar o ambiente Kubernetes no WSL:"
echo -e "   ${CYAN}./setup-kubernetes-wsl.sh${NC}"
echo -e "2. Após configurar o Kubernetes, implante o sistema Paxos:"
echo -e "   ${CYAN}./deploy-paxos-k8s.sh${NC}"
echo -e "3. Para usar o ambiente virtual Python:"
echo -e "   ${CYAN}source ./venv/bin/activate${NC}"

echo -e "\n${BLUE}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}Instalação de dependências básicas concluída!${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"