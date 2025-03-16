#!/bin/bash

# Cores para saída
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Variáveis globais
CURRENT_CLIENT="client1"
CLIENT_ID="9"  # client1=9, client2=10
TIMEOUT=10
NAMESPACE="paxos"

clear
echo -e "${BLUE}

# Loop principal
while true; do
    show_menu
done═════════════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}              SISTEMA PAXOS - CLIENTE INTERATIVO                 ${NC}"
echo -e "${BLUE}═════════════════════════════════════════════════════════════════${NC}"

# Verificar se kubectl está disponível
if ! command -v kubectl &> /dev/null; then
    echo -e "${RED}[ERRO] kubectl não encontrado. Por favor, instale o kubectl antes de continuar.${NC}"
    exit 1
fi

# Verificar se o namespace paxos existe
if ! kubectl get namespace $NAMESPACE &> /dev/null; then
    echo -e "${RED}[ERRO] Namespace '$NAMESPACE' não encontrado. Execute ./deploy-paxos-k8s.sh primeiro.${NC}"
    exit 1
fi

# Função para executar comando em um pod
exec_in_pod() {
    local service=$1
    local namespace=$2
    local command=$3
    
    # Obter o pod correspondente ao serviço
    local pod=$(kubectl get pods -n $namespace -l app=$service -o jsonpath="{.items[0].metadata.name}" 2>/dev/null)
    
    if [ -z "$pod" ]; then
        echo "${RED}[ERRO] Pod para $service não encontrado${NC}" >&2
        return 1
    fi
    
    # Executar o comando no pod
    kubectl exec -n $namespace $pod -- bash -c "$command" 2>/dev/null
    return $?
}

# Função para verificar a disponibilidade do serviço
check_service() {
    local service=$1
    local namespace=$NAMESPACE
    
    # Verificar se o pod existe
    local pod=$(kubectl get pods -n $namespace -l app=$service -o jsonpath="{.items[0].metadata.name}" 2>/dev/null)
    
    if [ -z "$pod" ]; then
        echo -e "${RED}[ERRO] Serviço $service não está disponível (pod não encontrado)!${NC}"
        echo -e "${YELLOW}Verifique se o sistema Paxos está em execução com ./run.sh${NC}"
        return 1
    fi
    
    # Verificar se o pod está pronto
    local ready=$(kubectl get pod $pod -n $namespace -o jsonpath="{.status.containerStatuses[0].ready}" 2>/dev/null)
    
    if [ "$ready" != "true" ]; then
        echo -e "${RED}[ERRO] Serviço $service não está pronto!${NC}"
        echo -e "${YELLOW}Verifique o status do pod: kubectl describe pod $pod -n $namespace${NC}"
        return 1
    fi
    
    return 0
}

# Verificar disponibilidade dos clientes
if ! check_service "client1"; then
    echo -e "${RED}[ERRO] Client1 não está disponível. Impossível continuar.${NC}"
    exit 1
fi

if ! check_service "client2"; then
    echo -e "${YELLOW}[AVISO] Client2 não está disponível. Apenas Client1 será usado.${NC}"
fi

# Função para selecionar o cliente
select_client() {
    echo -e "\n${BLUE}────────────────── SELECIONAR CLIENTE ──────────────────${NC}"
    echo -e "1) Cliente 1 (ID: 9)"
    echo -e "2) Cliente 2 (ID: 10)"
    echo -e "v) Voltar ao menu principal"
    
    read -p "Escolha o cliente [1]: " client_choice
    
    case $client_choice in
        "2")
            if check_service "client2"; then
                CURRENT_CLIENT="client2"
                CLIENT_ID="10"
                echo -e "${GREEN}Cliente 2 selecionado.${NC}"
            else
                echo -e "${RED}Cliente 2 não está disponível. Usando Cliente 1.${NC}"
                CURRENT_CLIENT="client1"
                CLIENT_ID="9"
            fi
            ;;
        "v"|"V")
            return
            ;;
        *)
            CURRENT_CLIENT="client1"
            CLIENT_ID="9"
            echo -e "${GREEN}Cliente 1 selecionado.${NC}"
            ;;
    esac
}

# Função para escrever valor no sistema
write_value() {
    echo -e "\n${BLUE}────────────────── ENVIAR VALOR ──────────────────${NC}"
    echo -e "${YELLOW}Cliente atual: ${CURRENT_CLIENT} (ID: ${CLIENT_ID})${NC}"
    
    read -p "Digite o valor a ser enviado: " value
    
    if [ -z "$value" ]; then
        echo -e "${RED}Valor não pode ser vazio. Operação cancelada.${NC}"
        return
    fi
    
    echo -e "${YELLOW}Enviando valor '$value' para o sistema Paxos...${NC}"
    
    # Escapar aspas duplas no valor
    escaped_value=${value//\"/\\\"}
    
    # Usar comando exec_in_pod para enviar o valor
    response=$(exec_in_pod "$CURRENT_CLIENT" "$NAMESPACE" "curl -s -X POST http://localhost:6001/send -H 'Content-Type: application/json' -d '{\"value\":\"$escaped_value\"}'")
    
    if [ $? -eq 0 ] && [ ! -z "$response" ]; then
        echo -e "${GREEN}Resposta do sistema:${NC}"
        echo $response | python3 -m json.tool 2>/dev/null || echo $response
    else
        echo -e "${RED}Falha ao enviar o valor. Verifique se o sistema está em execução.${NC}"
    fi
}

# Função para ler valores do sistema
read_values() {
    echo -e "\n${BLUE}────────────────── LER VALORES ──────────────────${NC}"
    echo -e "${YELLOW}Cliente atual: ${CURRENT_CLIENT} (ID: ${CLIENT_ID})${NC}"
    
    echo -e "${YELLOW}Obtendo valores do sistema...${NC}"
    
    # Usar comando exec_in_pod para ler os valores
    response=$(exec_in_pod "$CURRENT_CLIENT" "$NAMESPACE" "curl -s http://localhost:6001/read")
    
    if [ $? -eq 0 ] && [ ! -z "$response" ]; then
        values=$(echo "$response" | python3 -c "import sys, json; data = json.load(sys.stdin); print('\n'.join([str(i+1) + '. ' + str(v) for i, v in enumerate(data.get('values', []))]))" 2>/dev/null)
        
        if [ -z "$values" ]; then
            echo -e "${YELLOW}Nenhum valor encontrado no sistema.${NC}"
        else
            echo -e "${GREEN}Valores obtidos:${NC}"
            echo -e "$values"
        fi
    else
        echo -e "${RED}Falha ao ler valores. Verifique se o sistema está em execução.${NC}"
    fi
}

# Função para ver respostas recebidas pelo cliente
view_responses() {
    echo -e "\n${BLUE}────────────────── VISUALIZAR RESPOSTAS ──────────────────${NC}"
    echo -e "${YELLOW}Cliente atual: ${CURRENT_CLIENT} (ID: ${CLIENT_ID})${NC}"
    
    echo -e "${YELLOW}Obtendo respostas recebidas pelo cliente...${NC}"
    
    # Usar comando exec_in_pod para obter as respostas
    response=$(exec_in_pod "$CURRENT_CLIENT" "$NAMESPACE" "curl -s http://localhost:6001/get-responses")
    
    if [ $? -eq 0 ] && [ ! -z "$response" ]; then
        echo -e "${GREEN}Resposta do sistema:${NC}"
        echo $response | python3 -m json.tool 2>/dev/null || echo $response
    else
        echo -e "${RED}Falha ao obter respostas. Verifique se o sistema está em execução.${NC}"
    fi
}

# Função para obter status do cliente
client_status() {
    echo -e "\n${BLUE}────────────────── STATUS DO CLIENTE ──────────────────${NC}"
    echo -e "${YELLOW}Cliente atual: ${CURRENT_CLIENT} (ID: ${CLIENT_ID})${NC}"
    
    echo -e "${YELLOW}Obtendo status do cliente...${NC}"
    
    # Usar comando exec_in_pod para obter o status
    response=$(exec_in_pod "$CURRENT_CLIENT" "$NAMESPACE" "curl -s http://localhost:6001/view-logs")
    
    if [ $? -eq 0 ] && [ ! -z "$response" ]; then
        echo -e "${GREEN}Status do cliente:${NC}"
        echo $response | python3 -m json.tool 2>/dev/null || echo $response
    else
        echo -e "${RED}Falha ao obter status. Verifique se o sistema está em execução.${NC}"
    fi
}

# Função para ver status do líder atual
leader_status() {
    echo -e "\n${BLUE}────────────────── STATUS DO LÍDER ──────────────────${NC}"
    
    # Verificar líder atual consultando qualquer proposer
    response=$(exec_in_pod "proposer1" "$NAMESPACE" "curl -s http://localhost:3001/view-logs")
    
    if [ $? -eq 0 ] && [ ! -z "$response" ]; then
        leader_id=$(echo "$response" | python3 -c "import sys, json; print(json.load(sys.stdin).get('current_leader', 'Nenhum líder eleito'))" 2>/dev/null)
        is_leader=$(echo "$response" | python3 -c "import sys, json; print(json.load(sys.stdin).get('is_leader', False))" 2>/dev/null)
        
        if [ "$is_leader" = "True" ]; then
            echo -e "${GREEN}Proposer 1 é o líder atual (ID: $leader_id)${NC}"
            proposer_port="3001"
            proposer="proposer1"
        else
            echo -e "${YELLOW}Líder atual: Proposer $leader_id${NC}"
            # Ajustar nome e porta do líder
            proposer="proposer$leader_id"
            proposer_port="300$leader_id"
        fi
        
        # Obter status detalhado do líder
        if [[ $leader_id =~ ^[1-3]$ ]]; then
            echo -e "${YELLOW}Obtendo status detalhado do líder...${NC}"
            leader_response=$(exec_in_pod "$proposer" "$NAMESPACE" "curl -s http://localhost:$proposer_port/view-logs")
            if [ $? -eq 0 ] && [ ! -z "$leader_response" ]; then
                echo -e "${GREEN}Status do líder:${NC}"
                echo $leader_response | python3 -m json.tool 2>/dev/null || echo $leader_response
            fi
        else
            echo -e "${RED}Nenhum líder eleito ou o líder não está acessível.${NC}"
        fi
    else
        echo -e "${RED}Falha ao obter informações do líder. Verifique se o sistema está em execução.${NC}"
    fi
}

# Função para enviar diretamente para o proposer (bypass cliente)
direct_write() {
    echo -e "\n${BLUE}────────────────── ENVIO DIRETO PARA PROPOSER ──────────────────${NC}"
    
    # Selecionar proposer
    echo -e "1) Proposer 1"
    echo -e "2) Proposer 2"
    echo -e "3) Proposer 3"
    read -p "Escolha o proposer [1]: " proposer_choice
    
    case $proposer_choice in
        "2")
            proposer="proposer2"
            proposer_port="3002"
            ;;
        "3")
            proposer="proposer3"
            proposer_port="3003"
            ;;
        *)
            proposer="proposer1"
            proposer_port="3001"
            ;;
    esac
    
    # Verificar se o proposer está disponível
    if ! check_service "$proposer"; then
        echo -e "${RED}Proposer $proposer não está disponível. Operação cancelada.${NC}"
        return
    fi
    
    echo -e "${YELLOW}Proposer selecionado: $proposer${NC}"
    read -p "Digite o valor a ser enviado: " value
    
    if [ -z "$value" ]; then
        echo -e "${RED}Valor não pode ser vazio. Operação cancelada.${NC}"
        return
    fi
    
    echo -e "${YELLOW}Enviando valor '$value' diretamente para $proposer...${NC}"
    
    # Escapar aspas duplas no valor
    escaped_value=${value//\"/\\\"}
    
    # Usar comando exec_in_pod para enviar o valor diretamente para o proposer
    response=$(exec_in_pod "$proposer" "$NAMESPACE" "curl -s -X POST http://localhost:$proposer_port/propose -H 'Content-Type: application/json' -d '{\"value\":\"$escaped_value\", \"client_id\":$CLIENT_ID}'")
    
    if [ $? -eq 0 ] && [ ! -z "$response" ]; then
        echo -e "${GREEN}Resposta do proposer:${NC}"
        echo $response | python3 -m json.tool 2>/dev/null || echo $response
    else
        echo -e "${RED}Falha ao enviar o valor. Verifique se o sistema está em execução.${NC}"
    fi
}

# Função para ver o estado completo do sistema
system_status() {
    echo -e "\n${BLUE}────────────────── STATUS DO SISTEMA ──────────────────${NC}"
    
    # Verificar pods em execução
    echo -e "${YELLOW}Pods em execução:${NC}"
    kubectl get pods -n $NAMESPACE
    
    # Array de componentes para verificar
    components=(
        "proposer1:Proposer 1:3001"
        "proposer2:Proposer 2:3002" 
        "proposer3:Proposer 3:3003" 
        "acceptor1:Acceptor 1:4001" 
        "acceptor2:Acceptor 2:4002" 
        "acceptor3:Acceptor 3:4003"
        "learner1:Learner 1:5001" 
        "learner2:Learner 2:5002"
        "client1:Client 1:6001"
        "client2:Client 2:6002"
    )
    
    echo -e "\n${YELLOW}Verificando status de todos os componentes...${NC}"
    printf "${CYAN}%-15s %-15s %-10s${NC}\n" "COMPONENTE" "SAÚDE" "PORTA"
    echo -e "${CYAN}─────────────────────────────────────────${NC}"
    
    for component in "${components[@]}"; do
        IFS=':' read -r name desc port <<< "$component"
        
        # Verificar saúde do componente
        pod=$(kubectl get pods -n $NAMESPACE -l app=$name -o jsonpath="{.items[0].metadata.name}" 2>/dev/null)
        
        if [ -z "$pod" ]; then
            status="${RED}Offline${NC}"
        else
            # Verificar status ready do pod
            ready=$(kubectl get pod $pod -n $NAMESPACE -o jsonpath="{.status.containerStatuses[0].ready}" 2>/dev/null)
            
            if [ "$ready" = "true" ]; then
                status="${GREEN}Online${NC}"
            else
                status="${YELLOW}Iniciando${NC}"
            fi
        fi
        
        printf "%-15s ${status} %-10s\n" "$desc" "$port"
    done
    
    # Verificar líder atual
    echo -e "\n${YELLOW}Verificando líder atual...${NC}"
    response=$(exec_in_pod "proposer1" "$NAMESPACE" "curl -s http://localhost:3001/view-logs")
    
    if [ $? -eq 0 ] && [ ! -z "$response" ]; then
        leader_id=$(echo "$response" | python3 -c "import sys, json; print(json.load(sys.stdin).get('current_leader', 'Nenhum'))" 2>/dev/null)
        if [[ $leader_id =~ ^[1-3]$ ]]; then
            echo -e "${GREEN}Líder atual: Proposer $leader_id${NC}"
        else
            echo -e "${RED}Nenhum líder eleito${NC}"
        fi
    else
        echo -e "${RED}Não foi possível determinar o líder atual.${NC}"
    fi
}

# Menu principal
show_menu() {
    echo -e "\n${BLUE}═════════════════════ MENU PRINCIPAL ═════════════════════${NC}"
    echo -e "${YELLOW}Cliente atual:${NC} ${CYAN}${CURRENT_CLIENT}${NC} (ID: ${CLIENT_ID})"
    echo -e "${BLUE}─────────────────────────────────────────────────────────${NC}"
    echo -e "1) Selecionar cliente"
    echo -e "2) Enviar valor para o sistema"
    echo -e "3) Ler valores do sistema"
    echo -e "4) Visualizar respostas recebidas"
    echo -e "5) Ver status do cliente"
    echo -e "6) Ver status do líder"
    echo -e "7) Enviar diretamente para proposer (bypass cliente)"
    echo -e "8) Ver status completo do sistema"
    echo -e "q) Sair"
    echo -e "${BLUE}─────────────────────────────────────────────────────────${NC}"
    
    read -p "Escolha uma opção: " choice
    
    case $choice in
        "1") select_client ;;
        "2") write_value ;;
        "3") read_values ;;
        "4") view_responses ;;
        "5") client_status ;;
        "6") leader_status ;;
        "7") direct_write ;;
        "8") system_status ;;
        "q"|"Q") 
            echo -e "${GREEN}Encerrando cliente Paxos. Até logo!${NC}"
            exit 0 
            ;;
        *) 
            echo -e "${RED}Opção inválida. Tente novamente.${NC}"
            ;;
    esac
}