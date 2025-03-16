#!/bin/bash

# Cores para output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
GRAY='\033[0;37m'
NC='\033[0m' # No Color

NAMESPACE="paxos"

show_section_header() {
    echo -e "\n${BLUE}═════════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}              $1              ${NC}"
    echo -e "${BLUE}═════════════════════════════════════════════════════════════════${NC}"
}

show_subsection_header() {
    echo -e "\n${CYAN}────────────────── $1 ──────────────────${NC}"
}

run_command() {
    echo -e "${YELLOW}Executando: ${GRAY}$1${NC}"
    eval "$1"
    return $?
}

test_curl() {
    local url=$1
    local expect_code=${2:-200}
    
    echo -e "${YELLOW}Testando conexão HTTP para $url${NC}"
    local result=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 "$url")
    
    if [ "$result" == "$expect_code" ]; then
        echo -e "${GREEN}✓ Conexão bem-sucedida (HTTP $result)${NC}"
        return 0
    else
        echo -e "${RED}✗ Falha na conexão (HTTP $result, esperado $expect_code)${NC}"
        return 1
    fi
}

# Banner inicial
clear
show_section_header "SISTEMA PAXOS - DIAGNÓSTICO COMPLETO"

# Verificar prerequisites
show_subsection_header "VERIFICANDO PRÉ-REQUISITOS"

# Verificar kubectl
if ! command -v kubectl &> /dev/null; then
    echo -e "${RED}[ERRO] kubectl não encontrado. Por favor, instale o kubectl para continuar.${NC}"
    exit 1
else
    echo -e "${GREEN}✓ kubectl encontrado${NC}"
fi

# Verificar minikube
if ! command -v minikube &> /dev/null; then
    echo -e "${RED}[ERRO] minikube não encontrado. Por favor, instale o minikube para continuar.${NC}"
    exit 1
else
    echo -e "${GREEN}✓ minikube encontrado: $(minikube version --short)${NC}"
fi

# Verificar status do minikube
if ! minikube status | grep -q "Running"; then
    echo -e "${RED}[ERRO] minikube não está rodando. Por favor, inicie o minikube antes de continuar.${NC}"
    exit 1
else
    echo -e "${GREEN}✓ minikube está rodando${NC}"
fi

# Verificar namespace paxos
if ! kubectl get namespace $NAMESPACE &> /dev/null; then
    echo -e "${RED}[ERRO] Namespace '$NAMESPACE' não encontrado. Execute ./deploy-paxos-k8s.sh primeiro.${NC}"
    exit 1
else
    echo -e "${GREEN}✓ namespace '$NAMESPACE' encontrado${NC}"
fi

# 1. Verificação de serviços e pods
show_section_header "VERIFICAÇÃO DE SERVIÇOS E PODS"

# Verificar todos os serviços
show_subsection_header "SERVIÇOS CRIADOS"
run_command "kubectl get services -n $NAMESPACE"

# Verificar todos os pods
show_subsection_header "PODS CRIADOS"
run_command "kubectl get pods -n $NAMESPACE"

# Obter URLs dos serviços externos
show_subsection_header "URLs DOS SERVIÇOS"

echo -e "${YELLOW}Obtendo URLs dos serviços via NodePort...${NC}"

# Extrair informações diretamente sem usar o comando minikube service --url
get_node_port_url() {
    local service=$1
    local timeout=5

    # Usar timeout para evitar que o comando fique travado
    local node_ip=$(timeout $timeout minikube ip 2>/dev/null || echo "")
    
    if [ -z "$node_ip" ]; then
        echo -e "${YELLOW}Não foi possível obter o IP do minikube, usando localhost...${NC}"
        node_ip="localhost"
    fi

    # Obter as portas NodePort
    local api_port=$(kubectl get service $service -n $NAMESPACE -o jsonpath="{.spec.ports[?(@.name=='api')].nodePort}")
    local monitor_port=$(kubectl get service $service -n $NAMESPACE -o jsonpath="{.spec.ports[?(@.name=='monitor')].nodePort}")
    
    if [ -n "$api_port" ]; then
        echo -e "API: ${CYAN}http://$node_ip:$api_port${NC}"
    else
        echo -e "API: ${RED}[Não disponível]${NC}"
    fi
    
    if [ -n "$monitor_port" ]; then
        echo -e "Monitor: ${CYAN}http://$node_ip:$monitor_port${NC}"
    else
        echo -e "Monitor: ${RED}[Não disponível]${NC}"
    fi
}

# Mostrar URLs construídas para cada serviço externo
echo -e "\n${YELLOW}Client1-external:${NC}"
get_node_port_url "client1-external"

echo -e "\n${YELLOW}Proposer1-external:${NC}"
get_node_port_url "proposer1-external"

echo -e "\n${YELLOW}Learner1-external:${NC}"
get_node_port_url "learner1-external"

# Mostrar comando alternativo
echo -e "\n${YELLOW}Para acessar os serviços diretamente via browser ou terminal:${NC}"
echo -e "1. ${CYAN}Use as URLs acima${NC} com o IP/porta NodePort"
echo -e "2. ${CYAN}OU abra um novo terminal e execute:${NC}"
echo -e "   ${GRAY}minikube service client1-external -n $NAMESPACE --url${NC}"
echo -e "   ${GRAY}minikube service proposer1-external -n $NAMESPACE --url${NC}"

# 2. Verificação de definições e status dos deployments
show_section_header "VERIFICAÇÃO DE DEPLOYMENTS"

# Verificar status de cada deployment
show_subsection_header "STATUS DOS DEPLOYMENTS"
for deployment in proposer1 proposer2 proposer3 acceptor1 acceptor2 acceptor3 learner1 learner2 client1 client2; do
    echo -e "${YELLOW}Verificando status de $deployment:${NC}"
    kubectl rollout status deployment/$deployment -n $NAMESPACE --timeout=10s
done

# Verificar definição detalhada de um proposer
show_subsection_header "DEFINIÇÃO DETALHADA DO PROPOSER1"
run_command "kubectl describe pod -n $NAMESPACE -l app=proposer1 | head -n 30"

# 3. Verificação de redes e DNS
show_section_header "VERIFICAÇÃO DE REDE E DNS"

# Verificar o status do CoreDNS
show_subsection_header "STATUS DO COREDNS"
run_command "kubectl get pods -n kube-system -l k8s-app=kube-dns"

# Teste de DNS dentro do cluster
show_subsection_header "TESTE DE DNS DENTRO DO CLUSTER"
echo -e "${YELLOW}Executando teste de DNS dentro do cluster...${NC}"
kubectl run -n $NAMESPACE dns-test --rm -i --restart=Never --image=busybox:1.28 -- nslookup kubernetes.default

# Teste de Conectividade entre Pods
show_subsection_header "TESTE DE CONECTIVIDADE ENTRE PODS"
echo -e "${YELLOW}Testando conectividade entre pods...${NC}"

test_script=$(cat <<EOF
#!/bin/sh
echo "Testando conexões para outros serviços..."
echo "\n=== Teste de DNS para serviços Paxos ==="
for svc in proposer1 proposer2 proposer3 acceptor1 acceptor2 acceptor3 learner1 learner2 client1 client2; do
  echo -n "Resolvendo \$svc... "
  if nslookup \$svc.$NAMESPACE.svc.cluster.local > /dev/null 2>&1; then
    echo "✅ OK"
  else
    echo "❌ FALHA"
  fi
done

echo "\n=== Teste de conectividade HTTP ==="
for svc in proposer1 proposer2 proposer3 acceptor1 acceptor2 acceptor3 learner1 learner2 client1 client2; do
  echo -n "Conectando a \$svc:8000/health... "
  if wget -q --spider --timeout=2 http://\$svc.$NAMESPACE.svc.cluster.local:8000/health 2>/dev/null; then
    echo "✅ OK"
  else
    echo "❌ FALHA"
  fi
done
EOF
)

kubectl run -n $NAMESPACE network-test --rm -i --restart=Never --image=busybox:1.28 --command -- sh -c "$test_script"

# 4. Verificação de logs
show_section_header "VERIFICAÇÃO DE LOGS"

# Função para obter logs condensados
get_condensed_logs() {
    local app=$1
    local lines=${2:-20}
    echo -e "${YELLOW}Últimas $lines linhas de logs para $app:${NC}"
    kubectl logs -n $NAMESPACE -l app=$app --tail=$lines
}

# Verificar logs dos principais componentes
show_subsection_header "LOGS DO PROPOSER1"
get_condensed_logs "proposer1"

show_subsection_header "LOGS DO ACCEPTOR1"
get_condensed_logs "acceptor1"

show_subsection_header "LOGS DO LEARNER1"
get_condensed_logs "learner1"

# 5. Teste de funcionalidade
show_section_header "TESTE DE FUNCIONALIDADE DO SISTEMA"

# Verificar se há um líder eleito
show_subsection_header "VERIFICAÇÃO DE LÍDER"
leader_check=$(kubectl exec -n $NAMESPACE $(kubectl get pods -n $NAMESPACE -l app=proposer1 -o jsonpath="{.items[0].metadata.name}") -- curl -s http://localhost:3001/view-logs)
current_leader=$(echo $leader_check | grep -o '"current_leader":[^,}]*' | cut -d':' -f2 | tr -d '"' 2>/dev/null)

if [ -z "$current_leader" ] || [ "$current_leader" = "null" ] || [ "$current_leader" = "None" ]; then
    echo -e "${RED}✗ Nenhum líder eleito!${NC}"
    
    # Tentar forçar eleição
    echo -e "${YELLOW}Tentando forçar eleição de líder...${NC}"
    election_result=$(kubectl exec -n $NAMESPACE $(kubectl get pods -n $NAMESPACE -l app=proposer1 -o jsonpath="{.items[0].metadata.name}") -- curl -s -X POST http://localhost:3001/propose -H 'Content-Type: application/json' -d '{"value":"force_election_test","client_id":9}')
    echo -e "Resultado: $election_result"
    
    # Aguardar um pouco e verificar novamente
    echo -e "${YELLOW}Aguardando 5 segundos para eleição...${NC}"
    sleep 5
    
    leader_check=$(kubectl exec -n $NAMESPACE $(kubectl get pods -n $NAMESPACE -l app=proposer1 -o jsonpath="{.items[0].metadata.name}") -- curl -s http://localhost:3001/view-logs)
    current_leader=$(echo $leader_check | grep -o '"current_leader":[^,}]*' | cut -d':' -f2 | tr -d '"' 2>/dev/null)
    
    if [ -z "$current_leader" ] || [ "$current_leader" = "null" ] || [ "$current_leader" = "None" ]; then
        echo -e "${RED}✗ Ainda não há líder eleito após tentativa de forçar eleição${NC}"
    else
        echo -e "${GREEN}✓ Líder eleito após tentativa: Proposer $current_leader${NC}"
    fi
else
    echo -e "${GREEN}✓ Líder atual: Proposer $current_leader${NC}"
fi

# Teste de envio de proposta
show_subsection_header "TESTE DE ENVIO DE PROPOSTA"
echo -e "${YELLOW}Enviando proposta de teste...${NC}"
proposal_result=$(kubectl exec -n $NAMESPACE $(kubectl get pods -n $NAMESPACE -l app=client1 -o jsonpath="{.items[0].metadata.name}") -- curl -s -X POST http://localhost:6001/send -H 'Content-Type: application/json' -d '{"value":"test_value_'$(date +%s)'"}')
echo -e "Resultado da proposta: $proposal_result"

# Aguardar processamento
echo -e "${YELLOW}Aguardando 3 segundos para processamento...${NC}"
sleep 3

# Verificar se o valor foi aprendido
echo -e "${YELLOW}Verificando valores aprendidos...${NC}"
learned_values=$(kubectl exec -n $NAMESPACE $(kubectl get pods -n $NAMESPACE -l app=client1 -o jsonpath="{.items[0].metadata.name}") -- curl -s http://localhost:6001/read)
echo -e "Valores aprendidos: $learned_values"

# 6. Teste de resiliência (opcional)
show_subsection_header "TESTES DE RESILIÊNCIA (OPCIONAL)"
echo -e "${YELLOW}Deseja executar testes de resiliência? [s/N]${NC}"
read -p "> " run_resilience

if [[ "$run_resilience" == "s" || "$run_resilience" == "S" ]]; then
    echo -e "${YELLOW}Simulando falha do pod acceptor1...${NC}"
    kubectl delete pod -n $NAMESPACE -l app=acceptor1 --wait=false
    
    echo -e "${YELLOW}Aguardando recriação do pod...${NC}"
    sleep 5
    
    echo -e "${YELLOW}Status dos pods após simulação de falha:${NC}"
    kubectl get pods -n $NAMESPACE
    
    echo -e "${YELLOW}Tentando enviar nova proposta após falha...${NC}"
    kubectl exec -n $NAMESPACE $(kubectl get pods -n $NAMESPACE -l app=client1 -o jsonpath="{.items[0].metadata.name}") -- curl -s -X POST http://localhost:6001/send -H 'Content-Type: application/json' -d '{"value":"test_after_failure_'$(date +%s)'"}'
    
    echo -e "${YELLOW}Aguardando processamento...${NC}"
    sleep 3
    
    echo -e "${YELLOW}Verificando valores aprendidos após falha:${NC}"
    kubectl exec -n $NAMESPACE $(kubectl get pods -n $NAMESPACE -l app=client1 -o jsonpath="{.items[0].metadata.name}") -- curl -s http://localhost:6001/read
else
    echo -e "${GRAY}Testes de resiliência pulados${NC}"
fi

# 7. Resumo e verificação final
show_section_header "RESUMO DO DIAGNÓSTICO"

# Verificar status final de todos os pods
echo -e "${YELLOW}Status final de todos os pods:${NC}"
kubectl get pods -n $NAMESPACE

# Verificar status de cada componente por tipo
pods_status=$(kubectl get pods -n $NAMESPACE -o json)

total_pods=$(echo "$pods_status" | jq '.items | length')
running_pods=$(echo "$pods_status" | jq '[.items[] | select(.status.phase=="Running")] | length')
ready_pods=$(echo "$pods_status" | jq '[.items[] | select(.status.containerStatuses[0].ready==true)] | length')

# Exibir resumo
echo -e "\n${CYAN}RESUMO DE STATUS:${NC}"
echo -e "Total de pods: $total_pods"
echo -e "Pods rodando: $running_pods"
echo -e "Pods prontos: $ready_pods"

if [ "$ready_pods" -eq "$total_pods" ]; then
    echo -e "\n${GREEN}✅ TODOS OS PODS ESTÃO PRONTOS E FUNCIONANDO${NC}"
else
    echo -e "\n${RED}⚠️ EXISTEM PODS QUE NÃO ESTÃO PRONTOS ($ready_pods/$total_pods)${NC}"
fi

if [ -n "$current_leader" ] && [ "$current_leader" != "null" ] && [ "$current_leader" != "None" ]; then
    echo -e "${GREEN}✅ SISTEMA TEM UM LÍDER ELEITO (Proposer $current_leader)${NC}"
else
    echo -e "${RED}⚠️ SISTEMA NÃO TEM UM LÍDER ELEITO${NC}"
fi

echo -e "\n${BLUE}═════════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}Diagnóstico do sistema Paxos concluído!${NC}"
echo -e "${BLUE}═════════════════════════════════════════════════════════════════${NC}"