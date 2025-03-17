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
    echo -e "  -d, --docker-logs   Inclui logs do Docker para cada componente"
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
        -d|--docker-logs)
            DOCKER_LOGS=true
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

# Verificar se o Docker está disponível
if ! command -v docker &> /dev/null; then
    echo -e "${RED}[ERRO] Docker não encontrado. Por favor, instale o Docker antes de continuar.${NC}"
    exit 1
fi

# Verificar se os contêineres estão em execução
if ! docker ps | grep -q "proposer1"; then
    echo -e "${RED}[ERRO] Contêiner proposer1 não encontrado. Execute ./deploy.sh primeiro.${NC}"
    exit 1
fi

# Função para executar comando em um contêiner
exec_in_container() {
    local container=$1
    local command=$2
    
    docker exec $container bash -c "$command" 2>/dev/null
    return $?
}

# Função para obter logs Docker de um contêiner
get_docker_logs() {
    local container=$1
    local lines=${2:-10}
    
    docker logs $container --tail=$lines 2>/dev/null
    return $?
}

# Função para verificar a disponibilidade do serviço
check_service() {
    local container=$1
    
    # Verificar se o contêiner existe e está em execução
    if ! docker ps | grep -q "$container"; then
        return 1
    fi
    
    # Verificar se o serviço está respondendo
    local port=0
    if [[ $container == proposer* ]]; then
        port=$((3000 + ${container#proposer}))
    elif [[ $container == acceptor* ]]; then
        port=$((4000 + ${container#acceptor}))
    elif [[ $container == learner* ]]; then
        port=$((5000 + ${container#learner}))
    elif [[ $container == client* ]]; then
        port=$((6000 + ${container#client}))
    fi
    
    if [ $port -ne 0 ]; then
        if exec_in_container $container "curl -s http://localhost:$port/health" &> /dev/null; then
            return 0
        fi
    fi
    
    return 1
}

# Função para obter logs de um serviço
get_service_logs() {
    local container=$1
    local port=$2
    
    # Obter logs do serviço via API
    local response=$(exec_in_container "$container" "curl -s http://localhost:$port/view-logs")
    
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
            if check_service "proposer$i"; then
                local port=$((3000 + i))
                local logs=$(get_service_logs "proposer$i" "$port")
                if [ ! -z "$logs" ]; then
                    # Extrair eventos significativos
                    local events=$(parse_proposer_logs "$logs")
                    if [ ! -z "$events" ]; then
                        PROPOSER_LOGS+=("[$timestamp] $events")
                    fi
                    
                    # Adicionar logs do Docker se solicitado
                    if [ "$DOCKER_LOGS" = true ] && [ "$VERBOSE" = true ]; then
                        local docker_logs=$(get_docker_logs "proposer$i" 3)
                        if [ ! -z "$docker_logs" ]; then
                            PROPOSER_LOGS+=("[$timestamp] ${GRAY}[DOCKER LOGS] $docker_logs${NC}")
                        fi
                    fi
                fi
            fi
        done
    fi
    
    # Verificar e obter logs dos acceptors
    if [[ "$DISPLAY_MODE" == "all" || "$DISPLAY_MODE" == "acceptors" ]]; then
        for i in {1..3}; do
            if check_service "acceptor$i"; then
                local port=$((4000 + i))
                local logs=$(get_service_logs "acceptor$i" "$port")
                if [ ! -z "$logs" ]; then
                    # Extrair eventos significativos
                    local events=$(parse_acceptor_logs "$logs")
                    if [ ! -z "$events" ]; then
                        ACCEPTOR_LOGS+=("[$timestamp] $events")
                    fi
                    
                    # Adicionar logs do Docker se solicitado
                    if [ "$DOCKER_LOGS" = true ] && [ "$VERBOSE" = true ]; then
                        local docker_logs=$(get_docker_logs "acceptor$i" 3)
                        if [ ! -z "$docker_logs" ]; then
                            ACCEPTOR_LOGS+=("[$timestamp] ${GRAY}[DOCKER LOGS] $docker_logs${NC}")
                        fi
                    fi
                fi
            fi
        done
    fi
    
    # Verificar e obter logs dos learners
    if [[ "$DISPLAY_MODE" == "all" || "$DISPLAY_MODE" == "learners" ]]; then
        for i in {1..2}; do
            if check_service "learner$i"; then
                local port=$((5000 + i))
                local logs=$(get_service_logs "learner$i" "$port")
                if [ ! -z "$logs" ]; then
                    # Extrair eventos significativos
                    local events=$(parse_learner_logs "$logs")
                    if [ ! -z "$events" ]; then
                        LEARNER_LOGS+=("[$timestamp] $events")
                    fi
                    
                    # Adicionar logs do Docker se solicitado
                    if [ "$DOCKER_LOGS" = true ] && [ "$VERBOSE" = true ]; then
                        local docker_logs=$(get_docker_logs "learner$i" 3)
                        if [ ! -z "$docker_logs" ]; then
                            LEARNER_LOGS+=("[$timestamp] ${GRAY}[DOCKER LOGS] $docker_logs${NC}")
                        fi
                    fi
                fi
            fi
        done
    fi
    
    # Verificar e obter logs dos clients
    if [[ "$DISPLAY_MODE" == "all" || "$DISPLAY_MODE" == "clients" ]]; then
        for i in {1..2}; do
            if check_service "client$i"; then
                local port=$((6000 + i))
                local logs=$(get_service_logs "client$i" "$port")
                if [ ! -z "$logs" ]; then
                    # Extrair eventos significativos
                    local events=$(parse_client_logs "$logs")
                    if [ ! -z "$events" ]; then
                        CLIENT_LOGS+=("[$timestamp] $events")
                    fi
                    
                    # Adicionar logs do Docker se solicitado
                    if [ "$DOCKER_LOGS" = true ] && [ "$VERBOSE" = true ]; then
                        local docker_logs=$(get_docker_logs "client$i" 3)
                        if [ ! -z "$docker_logs" ]; then
                            CLIENT_LOGS+=("[$timestamp] ${GRAY}[DOCKER LOGS] $docker_logs${NC}")
                        fi
                    fi
                fi
            fi
        done
    fi
    
    # Limitar o tamanho dos arrays de logs
    while [ ${#PROPOSER_LOGS[@]} -gt $MAX_LOGS ]; do
        PROPOSER_LOGS=("${PROPOSER_LOGS[@]:1}")
    done
    
    while [ ${#ACCEPTOR_LOGS[@]} -gt $MAX_LOGS ]; do
        ACCEPTOR_LOGS=("${ACCEPTOR_LOGS[@]:1}")
    done
    
    while [ ${#LEARNER_LOGS[@]} -gt $MAX_LOGS ]; do
        LEARNER_LOGS=("${LEARNER_LOGS[@]:1}")
    done
    
    while [ ${#CLIENT_LOGS[@]} -gt $MAX_LOGS ]; do
        CLIENT_LOGS=("${CLIENT_LOGS[@]:1}")
    done
}

# Função para exibir todos os logs
display_logs() {
    clear
    
    echo -e "${BLUE}═════════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}              SISTEMA PAXOS - MONITOR EM TEMPO REAL              ${NC}"
    echo -e "${BLUE}═════════════════════════════════════════════════════════════════${NC}"
    
    echo -e "${YELLOW}Atualizado em:${NC} $(date '+%Y-%m-%d %H:%M:%S')"
    echo -e "${YELLOW}Modo:${NC} $DISPLAY_MODE  ${YELLOW}Intervalo:${NC} ${UPDATE_INTERVAL}s  ${YELLOW}Verboso:${NC} $VERBOSE"
    
    # Verificar status do líder
    local leader_id=$(exec_in_container "proposer1" "curl -s http://localhost:3001/view-logs | python3 -c \"import sys, json; print(json.load(sys.stdin).get('current_leader', 'None'))\"" 2>/dev/null)
    
    if [ "$leader_id" == "None" ] || [ -z "$leader_id" ] || [ "$leader_id" == "null" ]; then
        echo -e "${RED}Sistema sem líder eleito!${NC}"
    else
        echo -e "${GREEN}Líder atual: Proposer $leader_id${NC}"
    fi
    
    echo -e "${BLUE}─────────────────────────────────────────────────────────────────${NC}"
    
    # Exibir logs dos proposers
    if [[ "$DISPLAY_MODE" == "all" || "$DISPLAY_MODE" == "proposers" ]]; then
        echo -e "${PURPLE}PROPOSERS:${NC}"
        
        if [ ${#PROPOSER_LOGS[@]} -eq 0 ]; then
            echo -e "${GRAY}Nenhum evento de proposer registrado.${NC}"
        else
            for log in "${PROPOSER_LOGS[@]}"; do
                echo -e "$log"
            done
        fi
        
        echo -e "${BLUE}─────────────────────────────────────────────────────────────────${NC}"
    fi
    
    # Exibir logs dos acceptors
    if [[ "$DISPLAY_MODE" == "all" || "$DISPLAY_MODE" == "acceptors" ]]; then
        echo -e "${GREEN}ACCEPTORS:${NC}"
        
        if [ ${#ACCEPTOR_LOGS[@]} -eq 0 ]; then
            echo -e "${GRAY}Nenhum evento de acceptor registrado.${NC}"
        else
            for log in "${ACCEPTOR_LOGS[@]}"; do
                echo -e "$log"
            done
        fi
        
        echo -e "${BLUE}─────────────────────────────────────────────────────────────────${NC}"
    fi
    
    # Exibir logs dos learners
    if [[ "$DISPLAY_MODE" == "all" || "$DISPLAY_MODE" == "learners" ]]; then
        echo -e "${CYAN}LEARNERS:${NC}"
        
        if [ ${#LEARNER_LOGS[@]} -eq 0 ]; then
            echo -e "${GRAY}Nenhum evento de learner registrado.${NC}"
        else
            for log in "${LEARNER_LOGS[@]}"; do
                echo -e "$log"
            done
        fi
        
        echo -e "${BLUE}─────────────────────────────────────────────────────────────────${NC}"
    fi
    
    # Exibir logs dos clients
    if [[ "$DISPLAY_MODE" == "all" || "$DISPLAY_MODE" == "clients" ]]; then
        echo -e "${BLUE}CLIENTS:${NC}"
        
        if [ ${#CLIENT_LOGS[@]} -eq 0 ]; then
            echo -e "${GRAY}Nenhum evento de client registrado.${NC}"
        else
            for log in "${CLIENT_LOGS[@]}"; do
                echo -e "$log"
            done
        fi
        
        echo -e "${BLUE}─────────────────────────────────────────────────────────────────${NC}"
    fi
    
    if [ "$FOLLOW_LOGS" = true ]; then
        echo -e "${YELLOW}Pressione Ctrl+C para sair${NC}"
    fi
}

# Inicialização
clear
echo -e "${BLUE}═════════════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}              SISTEMA PAXOS - MONITOR EM TEMPO REAL              ${NC}"
echo -e "${BLUE}═════════════════════════════════════════════════════════════════${NC}"
echo -e "${YELLOW}Inicializando monitor...${NC}"

# Loop principal
update_logs
display_logs

if [ "$FOLLOW_LOGS" = true ]; then
    # Capturar Ctrl+C para sair graciosamente
    trap 'echo -e "\n${GREEN}Monitor finalizado.${NC}"; exit 0' INT
    
    while true; do
        sleep $UPDATE_INTERVAL
        update_logs
        display_logs
    done
fi

echo -e "\n${GREEN}Monitor finalizado.${NC}"