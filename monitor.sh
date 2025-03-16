#!/bin/bash

# Cores para saída
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
GRAY='\033[0;37m'
NC='\033[0m' # No Color

# Variáveis globais
UPDATE_INTERVAL=3  # segundos
DISPLAY_MODE="all"  # all, proposers, acceptors, learners, clients
FOLLOW_LOGS=true
VERBOSE=false
MAX_LOGS=500  # Máximo de logs para manter em buffer
NAMESPACE="paxos"

# Matrizes para armazenar logs
declare -a PROPOSER_LOGS
declare -a ACCEPTOR_LOGS
declare -a LEARNER_LOGS
declare -a CLIENT_LOGS

# Função para exibir ajuda
show_help() {
    echo -e "${BLUE}═════════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}              SISTEMA PAXOS - MONITOR EM TEMPO REAL              ${NC}"
    echo -e "${BLUE}═════════════════════════════════════════════════════════════════${NC}"
    echo -e "Uso: $0 [opções]"
    echo -e ""
    echo -e "Opções:"
    echo -e "  -h, --help          Exibe esta mensagem de ajuda"
    echo -e "  -p, --proposers     Exibe apenas logs dos proposers"
    echo -e "  -a, --acceptors     Exibe apenas logs dos acceptors"
    echo -e "  -l, --learners      Exibe apenas logs dos learners"
    echo -e "  -c, --clients       Exibe apenas logs dos clients"
    echo -e "  -i, --interval N    Define o intervalo de atualização para N segundos (padrão: 3)"
    echo -e "  -n, --no-follow     Não segue os logs (exibe uma vez e sai)"
    echo -e "  -v, --verbose       Modo verboso (exibe mais detalhes)"
    echo -e "  -k, --kubectl-logs  Inclui logs do Kubernetes para cada componente"
    echo -e ""
    echo -e "Exemplos:"
    echo -e "  $0                     # Exibe todos os logs, atualizando a cada 3 segundos"
    echo -e "  $0 -p -i 5             # Exibe apenas logs dos proposers, atualizando a cada 5 segundos"
    echo -e "  $0 -al -n              # Exibe logs dos acceptors e learners uma única vez"
    echo -e "${BLUE}═════════════════════════════════════════════════════════════════${NC}"
}

# Processar argumentos da linha de comando
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            show_help
            exit 0
            ;;
        -p|--proposers)
            DISPLAY_MODE="proposers"
            shift
            ;;
        -a|--acceptors)
            DISPLAY_MODE="acceptors"
            shift
            ;;
        -l|--learners)
            DISPLAY_MODE="learners"
            shift
            ;;
        -c|--clients)
            DISPLAY_MODE="clients"
            shift
            ;;
        -i|--interval)
            UPDATE_INTERVAL="$2"
            shift
            shift
            ;;
        -n|--no-follow)
            FOLLOW_LOGS=false
            shift
            ;;
        -v|--verbose)
            VERBOSE=true
            shift
            ;;
        -k|--kubectl-logs)
            KUBECTL_LOGS=true
            shift
            ;;
        *)
            echo -e "${RED}Opção desconhecida: $1${NC}"
            show_help
            exit 1
            ;;
    esac
done

# Verificar se o UPDATE_INTERVAL é um número válido
if ! [[ "$UPDATE_INTERVAL" =~ ^[0-9]+$ ]]; then
    echo -e "${RED}Intervalo de atualização inválido: $UPDATE_INTERVAL${NC}"
    echo -e "${YELLOW}Usando intervalo padrão de 3 segundos.${NC}"
    UPDATE_INTERVAL=3
fi

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
        return 1
    fi
    
    # Verificar se o pod está pronto
    local ready=$(kubectl get pod $pod -n $namespace -o jsonpath="{.status.containerStatuses[0].ready}" 2>/dev/null)
    
    if [ "$ready" != "true" ]; then
        return 1
    fi
    
    # Executar o comando no pod
    kubectl exec -n $namespace $pod -- bash -c "$command" 2>/dev/null
    return $?
}

# Função para obter logs Kubernetes de um pod
get_kubectl_logs() {
    local service=$1
    local namespace=$2
    local lines=${3:-10}
    
    # Obter o pod correspondente ao serviço
    local pod=$(kubectl get pods -n $namespace -l app=$service -o jsonpath="{.items[0].metadata.name}" 2>/dev/null)
    
    if [ -z "$pod" ]; then
        return 1
    fi
    
    # Obter logs do pod
    kubectl logs $pod -n $namespace --tail=$lines 2>/dev/null
    return $?
}

# Função para verificar a disponibilidade do serviço
check_service() {
    local service=$1
    local namespace=$NAMESPACE
    
    # Verificar se o pod existe e está pronto
    local response=$(exec_in_pod "$service" "$namespace" "curl -s http://localhost:8000/health")
    
    if [ $? -eq 0 ] && [ ! -z "$response" ]; then
        return 0
    fi
    
    return 1
}

# Função para obter logs de um serviço
get_service_logs() {
    local service=$1
    local port=$2
    local namespace=$NAMESPACE
    
    # Obter logs do serviço via API
    local response=$(exec_in_pod "$service" "$namespace" "curl -s http://localhost:$port/view-logs")
    
    echo "$response"
}

# Função para extrair eventos relevantes dos logs do proposer
parse_proposer_logs() {
    local logs=$1
    local id=$(echo "$logs" | python3 -c "import sys, json; print(json.load(sys.stdin).get('id', 'unknown'))" 2>/dev/null)
    local is_leader=$(echo "$logs" | python3 -c "import sys, json; print(json.load(sys.stdin).get('is_leader', False))" 2>/dev/null)
    local proposal_counter=$(echo "$logs" | python3 -c "import sys, json; print(json.load(sys.stdin).get('proposal_counter', 0))" 2>/dev/null)
    local in_election=$(echo "$logs" | python3 -c "import sys, json; print(json.load(sys.stdin).get('in_election', False))" 2>/dev/null)
    local current_proposal=$(echo "$logs" | python3 -c "import sys, json; d=json.load(sys.stdin).get('current_proposal', {}); print(f\"número: {d.get('number', 'N/A')}, valor: {d.get('value', 'N/A')}, aceitos: {d.get('accepted_count', 'N/A')}, aguardando: {d.get('waiting_for_response', False)}\")" 2>/dev/null)
    local current_leader=$(echo "$logs" | python3 -c "import sys, json; print(json.load(sys.stdin).get('current_leader', 'nenhum'))" 2>/dev/null)
    
    if [ "$is_leader" = "True" ]; then
        echo -e "${PURPLE}[PROPOSER $id] LÍDER ATUAL${NC}"
    else
        if [ "$in_election" = "True" ]; then
            echo -e "${YELLOW}[PROPOSER $id] Em processo de eleição${NC}"
        else
            echo -e "${GRAY}[PROPOSER $id] Ativo, acompanhando o líder $current_leader${NC}"
        fi
    fi
    
    if [ "$VERBOSE" = true ]; then
        echo -e "${GRAY}[PROPOSER $id] Contador de propostas: $proposal_counter${NC}"
        echo -e "${GRAY}[PROPOSER $id] Proposta atual: $current_proposal${NC}"
    fi
}

# Função para extrair eventos relevantes dos logs do acceptor
parse_acceptor_logs() {
    local logs=$1
    local id=$(echo "$logs" | python3 -c "import sys, json; print(json.load(sys.stdin).get('id', 'unknown'))" 2>/dev/null)
    local highest_promised=$(echo "$logs" | python3 -c "import sys, json; print(json.load(sys.stdin).get('highest_promised_number', 0))" 2>/dev/null)
    local accepted_number=$(echo "$logs" | python3 -c "import sys, json; print(json.load(sys.stdin).get('accepted_proposal', {}).get('number', 'N/A'))" 2>/dev/null)
    local accepted_value=$(echo "$logs" | python3 -c "import sys, json; print(json.load(sys.stdin).get('accepted_proposal', {}).get('value', 'N/A'))" 2>/dev/null)
    
    if [ "$accepted_number" != "N/A" ] && [ "$accepted_number" != "0" ]; then
        echo -e "${GREEN}[ACCEPTOR $id] Aceitou proposta #$accepted_number com valor: $accepted_value${NC}"
    fi
    
    if [ "$VERBOSE" = true ]; then
        echo -e "${GRAY}[ACCEPTOR $id] Maior número prometido: $highest_promised${NC}"
    fi
}

# Função para extrair eventos relevantes dos logs do learner
parse_learner_logs() {
    local logs=$1
    local id=$(echo "$logs" | python3 -c "import sys, json; print(json.load(sys.stdin).get('id', 'unknown'))" 2>/dev/null)
    local learned_count=$(echo "$logs" | python3 -c "import sys, json; print(json.load(sys.stdin).get('learned_values_count', 0))" 2>/dev/null)
    local recent_values=$(echo "$logs" | python3 -c "import sys, json; values=json.load(sys.stdin).get('recent_learned_values', []); print('\\n'.join([f\"#{v.get('proposal_number', 'N/A')}: {v.get('value', 'N/A')}\" for v in values]))" 2>/dev/null)
    
    if [ ! -z "$recent_values" ]; then
        echo -e "${CYAN}[LEARNER $id] Valores aprendidos ($learned_count total):${NC}"
        echo -e "${CYAN}$recent_values${NC}"
    else
        echo -e "${GRAY}[LEARNER $id] Nenhum valor aprendido recentemente (total: $learned_count)${NC}"
    fi
}

# Função para extrair eventos relevantes dos logs do cliente
parse_client_logs() {
    local logs=$1
    local id=$(echo "$logs" | python3 -c "import sys, json; print(json.load(sys.stdin).get('id', 'unknown'))" 2>/dev/null)
    local responses_count=$(echo "$logs" | python3 -c "import sys, json; print(json.load(sys.stdin).get('responses_count', 0))" 2>/dev/null)
    local recent_responses=$(echo "$logs" | python3 -c "import sys, json; resp=json.load(sys.stdin).get('recent_responses', []); print('\\n'.join([f\"#{r.get('proposal_number', 'N/A')}: '{r.get('value', 'N/A')}' do learner {r.get('learner_id', 'N/A')}\" for r in resp]))" 2>/dev/null)
    
    if [ ! -z "$recent_responses" ]; then
        echo -e "${BLUE}[CLIENT $id] Respostas recebidas ($responses_count total):${NC}"
        echo -e "${BLUE}$recent_responses${NC}"
    else
        echo -e "${GRAY}[CLIENT $id] Nenhuma resposta recente (total: $responses_count)${NC}"
    fi
}

# Função para atualizar todos os logs
update_logs() {
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    
    # Verificar e obter logs dos proposers
    if [[ "$DISPLAY_MODE" == "all" || "$DISPLAY_MODE" == "proposers" ]]; then
        for i in {1..3}; do
            if check_service "proposer$i" >/dev/null; then
                local logs=$(get_service_logs "proposer$i" "300$i")
                if [ ! -z "$logs" ]; then
                    # Extrair eventos significativos
                    local events=$(parse_proposer_logs "$logs")
                    if [ ! -z "$events" ]; then
                        PROPOSER_LOGS+=("[$timestamp] $events")
                    fi
                    
                    # Adicionar logs do Kubernetes se solicitado
                    if [ "$KUBECTL_LOGS" = true ] && [ "$VERBOSE" = true ]; then
                        local k8s_logs=$(get_kubectl_logs "proposer$i" "$NAMESPACE" 3)
                        if [ ! -z "$k8s_logs" ]; then
                            PROPOSER_LOGS+=("[$timestamp] ${GRAY}[K8S LOGS] $k8s_logs${NC}")
                        fi
                    fi
                fi
            fi
        done
    fi