#!/bin/bash

# Cores para output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

clear
echo -e "${BLUE}═════════════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}              SISTEMA PAXOS - IMPLANTAÇÃO KUBERNETES              ${NC}"
echo -e "${BLUE}═════════════════════════════════════════════════════════════════${NC}"

echo -e "\n${YELLOW}Verificando pré-requisitos...${NC}"

# Verificar se o Docker está instalado
if ! command -v docker &> /dev/null; then
    echo -e "${RED}[ERRO] Docker não encontrado. Por favor, instale o Docker antes de continuar.${NC}"
    exit 1
fi

# Verificar se o kubectl está instalado
if ! command -v kubectl &> /dev/null; then
    echo -e "${RED}[ERRO] kubectl não encontrado. Por favor, instale o kubectl antes de continuar.${NC}"
    exit 1
fi

# Verificar se o cluster Minikube está em execução
if ! minikube status | grep -q "Running"; then
    echo -e "${YELLOW}Inicializando cluster Minikube...${NC}"
    minikube start --driver=docker || {
        echo -e "${RED}[ERRO] Falha ao inicializar Minikube. Verifique sua instalação.${NC}"
        exit 1
    }
    
    # Habilitar o add-on ingress do Minikube
    echo -e "${YELLOW}Habilitando add-on Ingress...${NC}"
    minikube addons enable ingress
else
    echo -e "${GREEN}Cluster Minikube já está em execução.${NC}"
fi

# Configurar Docker para usar o registro do Minikube
echo -e "${YELLOW}Configurando Docker para usar o registry do Minikube...${NC}"
eval $(minikube docker-env) || {
    echo -e "${RED}[ERRO] Falha ao configurar Docker para Minikube.${NC}"
    exit 1
}

# Construir a imagem Docker do nó Paxos
echo -e "\n${YELLOW}Construindo imagem Docker do nó Paxos...${NC}"
docker build -t paxos-node:latest ./nodes/ || {
    echo -e "${RED}[ERRO] Falha ao construir a imagem Docker.${NC}"
    exit 1
}

# Criar namespace paxos se não existir
echo -e "\n${YELLOW}Criando namespace 'paxos'...${NC}"
kubectl create namespace paxos 2>/dev/null || true

# Aplicar os manifestos Kubernetes
echo -e "${YELLOW}Aplicando manifestos Kubernetes...${NC}"
kubectl apply -f k8s/00-namespace.yaml
kubectl apply -f k8s/01-configmap.yaml
kubectl apply -f k8s/02-proposers.yaml
kubectl apply -f k8s/03-acceptors.yaml
kubectl apply -f k8s/04-learners.yaml
kubectl apply -f k8s/05-clients.yaml
kubectl apply -f k8s/07-nodeport-services.yaml

# Aguardar a inicialização de todos os pods
echo -e "${YELLOW}Aguardando inicialização dos pods...${NC}"
echo -e "Esta operação pode levar até 2 minutos..."

# Função para verificar se todos os pods estão prontos
check_pods_ready() {
    local ready=0
    local total=0
    
    # Contar pods prontos vs total
    while read -r line; do
        if [[ "$line" =~ ([0-9]+)/([0-9]+) ]]; then
            ready=$((ready + ${BASH_REMATCH[1]}))
            total=$((total + ${BASH_REMATCH[2]}))
        fi
    done < <(kubectl get pods -n paxos -o=custom-columns=READY:.status.containerStatuses[*].ready | grep -v READY)
    
    # Verificar se todos estão prontos
    if [ "$ready" -eq "$total" ] && [ "$total" -gt 0 ]; then
        return 0
    else
        return 1
    fi
}

# Esperar até que todos os pods estejam prontos (com timeout)
timeout=120 # segundos
elapsed=0
spinner=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
spin_idx=0

while ! check_pods_ready; do
    spin_char="${spinner[spin_idx]}"
    echo -ne "${YELLOW}${spin_char} Aguardando pods... ${elapsed}s/${timeout}s${NC}\r"
    
    spin_idx=$(( (spin_idx + 1) % ${#spinner[@]} ))
    sleep 1
    elapsed=$((elapsed + 1))
    
    if [ "$elapsed" -ge "$timeout" ]; then
        echo -e "\n${RED}[AVISO] Timeout aguardando pods. Alguns pods podem não estar prontos.${NC}"
        break
    fi
done

if [ "$elapsed" -lt "$timeout" ]; then
    echo -e "\n${GREEN}Todos os pods estão prontos!${NC}"
fi

# Aplicar ingress após os serviços estarem prontos
echo -e "${YELLOW}Configurando Ingress...${NC}"
kubectl apply -f k8s/06-ingress.yaml

# Obter informações do cluster
echo -e "\n${BLUE}════════════════════ STATUS DO CLUSTER ════════════════════${NC}"
kubectl get pods -n paxos

# Obter URLs de acesso
echo -e "\n${BLUE}═════════════════════ ACESSOS AO SISTEMA ═════════════════════${NC}"
CLIENT_URL=$(minikube service client1-external -n paxos --url | head -n1 2>/dev/null || echo "URL não disponível")
MONITOR_URL=$(minikube service client1-external -n paxos --url | tail -n1 2>/dev/null || echo "URL não disponível")

echo -e "${GREEN}URL do Cliente: ${CLIENT_URL}${NC}"
echo -e "${GREEN}URL do Monitor: ${MONITOR_URL}${NC}"

echo -e "${YELLOW}Para acessar diretamente um serviço:${NC}"
echo -e "  minikube service client1-external -n paxos"
echo -e "  minikube service proposer1-external -n paxos"
echo -e "  minikube service learner1-external -n paxos"

echo -e "\n${BLUE}════════════════════ SCRIPTS DISPONÍVEIS ════════════════════${NC}"
echo -e "  ${GREEN}./run.sh${NC} - Iniciar sistema Paxos após a implantação"
echo -e "  ${GREEN}./paxos-client.sh${NC} - Cliente interativo"
echo -e "  ${GREEN}./monitor.sh${NC} - Monitorar o sistema em tempo real"
echo -e "  ${GREEN}./cleanup-paxos-k8s.sh${NC} - Remover a implantação"

echo -e "\n${BLUE}═══════════════════════════════════════════════════════════════${NC}"
echo -e "Sistema Paxos implantado com sucesso no Kubernetes!"
echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"