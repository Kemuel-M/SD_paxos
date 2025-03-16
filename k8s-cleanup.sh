#!/bin/bash

# Cores para output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

clear
echo -e "${BLUE}═════════════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}              SISTEMA PAXOS - LIMPEZA KUBERNETES                 ${NC}"
echo -e "${BLUE}═════════════════════════════════════════════════════════════════${NC}"

# Verificar se kubectl está disponível
if ! command -v kubectl &> /dev/null; then
    echo -e "${RED}[ERRO] kubectl não encontrado. Por favor, instale o kubectl antes de continuar.${NC}"
    exit 1
fi

echo -e "\n${YELLOW}Removendo recursos Kubernetes do sistema Paxos...${NC}"

# Verificar se o namespace existe
if ! kubectl get namespace paxos &> /dev/null; then
    echo -e "${YELLOW}Namespace 'paxos' não encontrado. Nada para limpar.${NC}"
    
    # Perguntar se deseja parar o cluster Minikube
    read -p "Deseja parar o cluster Minikube? (s/n): " STOP_CLUSTER
    if [[ "$STOP_CLUSTER" == "s" || "$STOP_CLUSTER" == "S" ]]; then
        echo -e "${YELLOW}Parando cluster Minikube...${NC}"
        minikube stop
        echo -e "${GREEN}Cluster Minikube parado.${NC}"
    fi
    
    exit 0
fi

# Função para verificar e remover recursos com segurança
remove_resource() {
    local resource_type=$1
    local resource_file=$2
    
    echo -e "${YELLOW}Removendo ${resource_type}...${NC}"
    
    if [ -f "$resource_file" ]; then
        kubectl delete -f "$resource_file" 2>/dev/null || true
        sleep 2
    else
        echo -e "${RED}[AVISO] Arquivo $resource_file não encontrado. Pulando.${NC}"
    fi
}

# Remover recursos na ordem inversa da criação para minimizar problemas
remove_resource "ingress" "k8s/06-ingress.yaml"
remove_resource "services nodeport" "k8s/07-nodeport-services.yaml"
remove_resource "clients" "k8s/05-clients.yaml"
remove_resource "learners" "k8s/04-learners.yaml"
remove_resource "acceptors" "k8s/03-acceptors.yaml"
remove_resource "proposers" "k8s/02-proposers.yaml"
remove_resource "configmap" "k8s/01-configmap.yaml"

# Aguardar um pouco para os recursos terminarem
echo -e "${YELLOW}Aguardando remoção de recursos...${NC}"
sleep 5

# Verificar se ainda há pods no namespace
if kubectl get pods -n paxos 2>/dev/null | grep -q -v "No resources found"; then
    echo -e "${YELLOW}Ainda existem pods no namespace. Forçando remoção...${NC}"
    kubectl delete pods --all -n paxos --grace-period=0 --force || true
    sleep 5
fi

# Verificar se ainda há recursos persistentes
if kubectl get pvc -n paxos 2>/dev/null | grep -q -v "No resources found"; then
    echo -e "${YELLOW}Removendo reivindicações de volume persistente...${NC}"
    kubectl delete pvc --all -n paxos || true
    sleep 3
fi

# Remover o namespace por último (remove todos os recursos dentro dele)
echo -e "${YELLOW}Removendo namespace 'paxos'...${NC}"
kubectl delete -f k8s/00-namespace.yaml || kubectl delete namespace paxos --grace-period=0 --force

# Verificar se o namespace foi removido
timeout=30
elapsed=0
while kubectl get namespace paxos &> /dev/null && [ "$elapsed" -lt "$timeout" ]; do
    echo -ne "${YELLOW}Aguardando remoção do namespace... ${elapsed}s/${timeout}s${NC}\r"
    sleep 1
    elapsed=$((elapsed + 1))
done

if kubectl get namespace paxos &> /dev/null; then
    echo -e "\n${RED}[AVISO] Não foi possível remover completamente o namespace 'paxos'.${NC}"
    echo -e "${YELLOW}Você pode tentar removê-lo manualmente mais tarde:${NC}"
    echo -e "kubectl delete namespace paxos --grace-period=0 --force"
else
    echo -e "\n${GREEN}Namespace 'paxos' removido com sucesso.${NC}"
fi

# Perguntar se deseja parar o cluster Minikube
read -p "Deseja parar o cluster Minikube? (s/n): " STOP_CLUSTER
if [[ "$STOP_CLUSTER" == "s" || "$STOP_CLUSTER" == "S" ]]; then
    echo -e "${YELLOW}Parando cluster Minikube...${NC}"
    minikube stop
    echo -e "${GREEN}Cluster Minikube parado.${NC}"
fi

# Perguntar se deseja excluir o cluster Minikube
read -p "Deseja excluir completamente o cluster Minikube? (s/n): " DELETE_CLUSTER
if [[ "$DELETE_CLUSTER" == "s" || "$DELETE_CLUSTER" == "S" ]]; then
    echo -e "${RED}Excluindo cluster Minikube...${NC}"
    minikube delete
    echo -e "${GREEN}Cluster Minikube excluído.${NC}"
fi

echo -e "\n${BLUE}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}Sistema Paxos removido com sucesso do Kubernetes!${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"