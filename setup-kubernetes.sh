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
echo -e "${BLUE}              PREPARAÇÃO DE AMBIENTE KUBERNETES NO WSL           ${NC}"
echo -e "${BLUE}═════════════════════════════════════════════════════════════════${NC}"

# Verificar sistema operacional
echo -e "\n${YELLOW}Verificando sistema operacional...${NC}"
if [ ! -f /etc/os-release ]; then
    echo -e "${RED}[ERRO] Arquivo /etc/os-release não encontrado. Este script é compatível apenas com WSL Ubuntu.${NC}"
    exit 1
fi

source /etc/os-release
if [[ "$NAME" != *"Ubuntu"* ]]; then
    echo -e "${RED}[ERRO] Este script foi projetado para Ubuntu no WSL. Sistema detectado: $NAME${NC}"
    exit 1
fi

echo -e "${GREEN}Sistema operacional: $NAME $VERSION_ID${NC}"

# Remover repositório do Kubernetes problemático, se existir
if [ -f /etc/apt/sources.list.d/kubernetes.list ]; then
    echo -e "${YELLOW}Removendo repositório problemático do Kubernetes...${NC}"
    sudo rm /etc/apt/sources.list.d/kubernetes.list
fi

# Verificar se o script de dependências foi executado
echo -e "\n${YELLOW}Verificando dependências essenciais...${NC}"
if ! command -v curl &> /dev/null || ! command -v jq &> /dev/null; then
    echo -e "${RED}[AVISO] Dependências essenciais não encontradas.${NC}"
    echo -e "${YELLOW}Execute primeiro o script install-dependencies.sh:${NC}"
    echo -e "${CYAN}./install-dependencies.sh${NC}"
    
    read -p "Deseja continuar mesmo assim? (s/n): " continue_anyway
    if [[ ! "$continue_anyway" =~ [sS] ]]; then
        echo -e "${YELLOW}Instalação abortada. Execute primeiro o script de dependências.${NC}"
        exit 1
    fi
fi

# Verificar se WSL está na versão 2
echo -e "\n${YELLOW}Verificando versão do WSL...${NC}"
if [ -f /proc/version ]; then
    if grep -q "microsoft" /proc/version && ! grep -q "WSL2" /proc/version; then
        echo -e "${YELLOW}Você parece estar usando WSL1. Recomendamos o uso do WSL2 para melhor desempenho.${NC}"
        echo -e "${YELLOW}Você pode converter para WSL2 usando o PowerShell do Windows:${NC}"
        echo -e "${CYAN}wsl --set-version Ubuntu-20.04 2${NC}"
    else
        echo -e "${GREEN}WSL2 detectado.${NC}"
    fi
else
    echo -e "${YELLOW}Não foi possível determinar a versão do WSL.${NC}"
fi

# Instalar Docker se não estiver instalado
if ! command -v docker &> /dev/null; then
    echo -e "\n${YELLOW}Instalando Docker...${NC}"
    
    # Remover versões antigas (se existirem)
    sudo apt-get remove -y docker docker-engine docker.io containerd runc || true
    
    # Adicionar repositório Docker
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -
    sudo add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"
    
    # Instalar Docker
    sudo apt-get update -qq
    sudo apt-get install -y docker-ce docker-ce-cli containerd.io
    
    # Configurar Docker para ser usado sem sudo
    sudo groupadd docker 2>/dev/null || true
    sudo usermod -aG docker $USER
    
    echo -e "${GREEN}Docker instalado com sucesso!${NC}"
    echo -e "${YELLOW}Para usar Docker sem sudo, você precisará reiniciar o WSL.${NC}"
    echo -e "${YELLOW}Após concluir este script, execute 'wsl --shutdown' no PowerShell e reabra o terminal WSL.${NC}"
else
    echo -e "${GREEN}Docker já está instalado: $(docker --version)${NC}"
    
    # Verificar se o usuário está no grupo docker
    if ! groups | grep -q docker; then
        echo -e "${YELLOW}Adicionando usuário ao grupo docker...${NC}"
        sudo groupadd docker 2>/dev/null || true
        sudo usermod -aG docker $USER
        echo -e "${YELLOW}Para aplicar as alterações, você precisará reiniciar o WSL.${NC}"
    fi
fi

# Iniciar serviço Docker
echo -e "\n${YELLOW}Iniciando serviço Docker...${NC}"
if ! sudo service docker status >/dev/null 2>&1; then
    sudo service docker start || {
        echo -e "${RED}[AVISO] Não foi possível iniciar o serviço Docker.${NC}"
        echo -e "${YELLOW}Após concluir este script, reinicie o WSL e execute: sudo service docker start${NC}"
    }
fi

# Instalar kubectl usando download direto (sem repositório)
if ! command -v kubectl &> /dev/null; then
    echo -e "\n${YELLOW}Instalando kubectl via download direto...${NC}"
    
    # Baixar a versão mais recente do kubectl
    echo -e "${YELLOW}Baixando kubectl...${NC}"
    curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
    
    # Tornar o arquivo executável
    chmod +x kubectl
    
    # Mover para o diretório bin
    echo -e "${YELLOW}Instalando kubectl em /usr/local/bin...${NC}"
    sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
    
    # Limpar arquivo baixado
    rm kubectl
    
    echo -e "${GREEN}kubectl instalado com sucesso!${NC}"
else
    echo -e "${GREEN}kubectl já está instalado: $(kubectl version --client --short 2>/dev/null || echo 'versão não disponível')${NC}"
fi

# Criação do diretório keyrings se não existir
sudo mkdir -p /etc/apt/keyrings

# Instalar kubelet e kubeadm (opcional, não necessário para Minikube)
if ! command -v kubeadm &> /dev/null; then
    echo -e "\n${YELLOW}Instalando kubelet, kubeadm e kubectl do repositório oficial...${NC}"
    
    # Adicionar chave GPG do Kubernetes (método moderno)
    sudo curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.32/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
    
    # Adicionar repositório (URL atualizada)
    echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.32/deb/ /" | sudo tee /etc/apt/sources.list.d/kubernetes.list
    
    # Atualizar e instalar
    if sudo apt-get update && sudo apt-get install -y kubelet kubeadm; then
        # Fixar versão para evitar atualizações automáticas
        sudo apt-mark hold kubelet kubeadm
        echo -e "${GREEN}Componentes do Kubernetes instalados com sucesso!${NC}"
    else
        echo -e "${YELLOW}Nota: Kubelet e Kubeadm não foram instalados, mas isso não afetará o uso do Minikube.${NC}"
        echo -e "${YELLOW}Minikube contém seu próprio ambiente Kubernetes e não requer esses componentes.${NC}"
    fi
else
    echo -e "${GREEN}Componentes do Kubernetes já estão instalados: $(kubeadm version -o short 2>/dev/null || echo 'versão não disponível')${NC}"
fi

# Instalar Minikube
if ! command -v minikube &> /dev/null; then
    echo -e "\n${YELLOW}Instalando Minikube...${NC}"
    
    # Baixar e instalar Minikube
    curl -LO https://storage.googleapis.com/minikube/releases/latest/minikube-linux-amd64
    sudo install minikube-linux-amd64 /usr/local/bin/minikube
    rm minikube-linux-amd64
    
    echo -e "${GREEN}Minikube instalado com sucesso!${NC}"
else
    echo -e "${GREEN}Minikube já está instalado: $(minikube version --short 2>/dev/null || echo 'versão não disponível')${NC}"
fi

# Instalar Helm
if ! command -v helm &> /dev/null; then
    echo -e "\n${YELLOW}Instalando Helm...${NC}"
    
    curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
    chmod 700 get_helm.sh
    ./get_helm.sh
    rm get_helm.sh
    
    echo -e "${GREEN}Helm instalado com sucesso!${NC}"
else
    echo -e "${GREEN}Helm já está instalado: $(helm version --short 2>/dev/null || echo 'versão não disponível')${NC}"
fi

# Testar Docker
echo -e "\n${YELLOW}Testando Docker...${NC}"
if docker run --rm hello-world &>/dev/null; then
    echo -e "${GREEN}Docker está funcionando corretamente!${NC}"
else
    echo -e "${RED}[AVISO] Teste do Docker falhou. Verifique se o serviço está em execução.${NC}"
    echo -e "${YELLOW}Execute 'sudo service docker start' após reiniciar o WSL.${NC}"
fi

# Testar configuração do Minikube
echo -e "\n${YELLOW}Verificando configuração do Minikube...${NC}"
if minikube config view &>/dev/null; then
    echo -e "${GREEN}Configuração do Minikube está correta.${NC}"
else
    echo -e "${YELLOW}Configurando Minikube para usar o driver Docker...${NC}"
    minikube config set driver docker
fi

# Se o Minikube já está em execução, exibir seu status
if minikube status &>/dev/null; then
    echo -e "${GREEN}Minikube já está em execução:${NC}"
    minikube status
else
    echo -e "${YELLOW}Minikube não está em execução. Você pode iniciá-lo com:${NC}"
    echo -e "${CYAN}minikube start --driver=docker${NC}"
fi

echo -e "\n${BLUE}═════════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}Ambiente Kubernetes preparado com sucesso!${NC}"
echo -e "${BLUE}═════════════════════════════════════════════════════════════════${NC}"

echo -e "\n${YELLOW}Próximos passos:${NC}"
echo -e "1. Reinicie o WSL para aplicar todas as alterações:"
echo -e "   - No PowerShell do Windows, execute: ${CYAN}wsl --shutdown${NC}"
echo -e "   - Reabra seu terminal WSL"
echo -e ""
echo -e "2. Inicie o cluster Minikube:"
echo -e "   ${CYAN}minikube start --driver=docker${NC}"
echo -e ""
echo -e "3. Verifique o status do cluster:"
echo -e "   ${CYAN}minikube status${NC}"
echo -e ""
echo -e "4. Implante o sistema Paxos:"
echo -e "   ${CYAN}./deploy-paxos-k8s.sh${NC}"
echo -e ""
echo -e "${BLUE}═════════════════════════════════════════════════════════════════${NC}"