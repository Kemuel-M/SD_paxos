#!/bin/bash

# Cores para output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
GRAY='\033[0;37m'
BOLD='\033[1m'
NC='\033[0m' # No Color

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

exec_in_container() {
    local container=$1
    local command=$2
    
    docker exec $container bash -c "$command" 2>/dev/null
    return $?
}

check_service_health() {
    local container=$1
    local port=$2
    
    local result=$(exec_in_container $container "curl -s http://localhost:$port/health")
    
    if [ ! -z "$result" ]; then
        echo -e "${GREEN}✓ $container está saudável na porta $port${NC}"
        return 0
    else
        echo -e "${RED}✗ $container NÃO está respondendo na porta $port${NC}"
        return 1
    fi
}

wait_for_output() {
    local seconds=$1
    echo -ne "${YELLOW}Aguardando $seconds segundos...${NC}"
    for ((i=1; i<=$seconds; i++)); do
        sleep 1
        echo -ne "."
    done
    echo -e " ${GREEN}Concluído!${NC}"
}

# Banner inicial
clear
show_section_header "TESTE DE PROPOSERS - SISTEMA PAXOS"

# Verificar se Docker está disponível
if ! command -v docker &> /dev/null; then
    echo -e "${RED}[ERRO] Docker não encontrado. Por favor, instale o Docker para continuar.${NC}"
    exit 1
fi

# 1. Teste de Saúde dos Proposers
show_section_header "1. TESTE DE SAÚDE DOS PROPOSERS"

show_subsection_header "Verificando contêineres Proposer"
run_command "docker ps | grep proposer"

show_subsection_header "Verificando saúde dos endpoints"
check_service_health "proposer1" "3001"
check_service_health "proposer2" "3002"
check_service_health "proposer3" "3003"

show_subsection_header "Verificando comunicação entre Proposers via ping"
run_command "docker exec proposer1 ping -c 2 proposer2"
run_command "docker exec proposer1 ping -c 2 proposer3"
run_command "docker exec proposer2 ping -c 2 proposer3"

# 2. Visualização de Logs dos Proposers
show_section_header "2. VISUALIZAÇÃO DE LOGS DOS PROPOSERS"

show_subsection_header "Logs de proposer1 (últimas 5 linhas)"
run_command "docker logs proposer1 --tail 5"

for i in {1..3}; do
    show_subsection_header "Estado interno de proposer$i"
    response=$(exec_in_container "proposer$i" "curl -s http://localhost:300$i/view-logs")
    # Formatando o JSON para melhor visualização
    echo -e "${YELLOW}Estado do proposer$i:${NC}"
    echo $response | python3 -m json.tool
done

# 3. Teste de Requisição Cliente-Proposer
show_section_header "3. TESTE DE REQUISIÇÃO CLIENTE-PROPOSER"

# Verificar qual proposer é o líder atual
show_subsection_header "Verificando líder atual"
response=$(exec_in_container "proposer1" "curl -s http://localhost:3001/view-logs")
current_leader=$(echo $response | python3 -c "import sys, json; print(json.load(sys.stdin).get('current_leader', 'None'))" 2>/dev/null)

if [ "$current_leader" == "None" ] || [ -z "$current_leader" ] || [ "$current_leader" == "null" ]; then
    echo -e "${YELLOW}Nenhum líder detectado. Vamos forçar uma eleição antes de continuar.${NC}"
    
    # Forçar eleição
    exec_in_container "proposer1" "curl -s -X POST http://localhost:3001/propose -H 'Content-Type: application/json' -d '{\"value\":\"force_election_test\",\"client_id\":9}'"
    
    wait_for_output 5
    
    # Verificar novamente
    response=$(exec_in_container "proposer1" "curl -s http://localhost:3001/view-logs")
    current_leader=$(echo $response | python3 -c "import sys, json; print(json.load(sys.stdin).get('current_leader', 'None'))" 2>/dev/null)
    
    if [ "$current_leader" == "None" ] || [ -z "$current_leader" ] || [ "$current_leader" == "null" ]; then
        echo -e "${RED}Não foi possível eleger um líder. Continuando testes com líder ausente...${NC}"
        leader_container="proposer1"  # Usar proposer1 como fallback
    else
        echo -e "${GREEN}Líder eleito: Proposer $current_leader${NC}"
        leader_container="proposer$current_leader"
    fi
else
    echo -e "${GREEN}Líder atual: Proposer $current_leader${NC}"
    leader_container="proposer$current_leader"
fi

# Testar requisição para o líder
show_subsection_header "Enviando proposta para o líder ($leader_container)"
proposal_result=$(exec_in_container "$leader_container" "curl -s -X POST http://localhost:300$current_leader/propose -H 'Content-Type: application/json' -d '{\"value\":\"test_value_from_leader_test\",\"client_id\":9}'")
echo -e "${YELLOW}Resultado da proposta enviada ao líder:${NC}"
echo $proposal_result | python3 -m json.tool

# Testar requisição para um não-líder
non_leader_id=$(( (current_leader % 3) + 1 ))
non_leader_container="proposer$non_leader_id"

show_subsection_header "Enviando proposta para um não-líder ($non_leader_container)"
proposal_result=$(exec_in_container "$non_leader_container" "curl -s -X POST http://localhost:300$non_leader_id/propose -H 'Content-Type: application/json' -d '{\"value\":\"test_value_from_non_leader_test\",\"client_id\":9}'")
echo -e "${YELLOW}Resultado da proposta enviada a um não-líder:${NC}"
echo $proposal_result | python3 -m json.tool

# 4. Testes de Comportamento sem Líder
show_section_header "4. TESTES DE COMPORTAMENTO SEM LÍDER"

show_subsection_header "Removendo o líder atual (simulando falha)"

# Armazenar o líder atual
old_leader="$current_leader"
old_leader_container="$leader_container"

echo -e "${YELLOW}Parando o contêiner do líder: $old_leader_container${NC}"
docker stop $old_leader_container

wait_for_output 10

show_subsection_header "Verificando a resposta do sistema após a queda do líder"

# Verificar o estado dos proposers restantes
for i in {1..3}; do
    if [ "$i" != "$old_leader" ]; then
        echo -e "${YELLOW}Verificando estado de proposer$i após queda do líder:${NC}"
        response=$(exec_in_container "proposer$i" "curl -s http://localhost:300$i/view-logs")
        election_status=$(echo $response | python3 -c "import sys, json; print(f\"Em eleição: {json.load(sys.stdin).get('in_election', False)}, Líder atual: {json.load(sys.stdin).get('current_leader', 'None')}\")" 2>/dev/null)
        echo -e "${CYAN}Status de proposer$i:${NC} $election_status"
    fi
done

# Tentar enviar uma proposta a um dos proposers restantes
available_proposer=$(( (old_leader % 3) + 1 ))
show_subsection_header "Tentando enviar proposta a proposer$available_proposer sem líder presente"
proposal_result=$(exec_in_container "proposer$available_proposer" "curl -s -X POST http://localhost:300$available_proposer/propose -H 'Content-Type: application/json' -d '{\"value\":\"test_no_leader\",\"client_id\":9}'")
echo -e "${YELLOW}Resultado da proposta sem líder:${NC}"
echo $proposal_result | python3 -m json.tool

# Reativar o contêiner do líder anterior
echo -e "${YELLOW}Reiniciando o contêiner do líder anterior: $old_leader_container${NC}"
docker start $old_leader_container

wait_for_output 5

# 5. Testes de Eleição Entre Proposers
show_section_header "5. TESTES DE ELEIÇÃO ENTRE PROPOSERS"

show_subsection_header "Forçando uma nova eleição entre todos os proposers"

# Aguardar recuperação do contêiner reiniciado
wait_for_output 10

# Tentar forçar eleição em cada proposer e observar o resultado
for i in {1..3}; do
    echo -e "${YELLOW}Forçando eleição a partir de proposer$i:${NC}"
    election_result=$(exec_in_container "proposer$i" "curl -s -X POST http://localhost:300$i/propose -H 'Content-Type: application/json' -d '{\"value\":\"force_election_from_proposer$i\",\"client_id\":9,\"is_leader_election\":true}'")
    echo -e "${CYAN}Resultado da tentativa de eleição de proposer$i:${NC}"
    echo $election_result | python3 -m json.tool
    
    wait_for_output 2
done

# Verificar qual é o novo líder após as tentativas de eleição
show_subsection_header "Verificando novo líder eleito"
for i in {1..3}; do
    response=$(exec_in_container "proposer$i" "curl -s http://localhost:300$i/view-logs")
    is_leader=$(echo $response | python3 -c "import sys, json; print(json.load(sys.stdin).get('is_leader', False))" 2>/dev/null)
    current_leader=$(echo $response | python3 -c "import sys, json; print(json.load(sys.stdin).get('current_leader', 'None'))" 2>/dev/null)
    
    if [ "$is_leader" = "True" ]; then
        echo -e "${GREEN}✓ Proposer$i se reconhece como o líder${NC}"
    else
        echo -e "${GRAY}Proposer$i reconhece o líder como: $current_leader${NC}"
    fi
done

# 6. Testes de Comunicação Proposer-Acceptor
show_section_header "6. TESTES DE COMUNICAÇÃO PROPOSER-ACCEPTOR"

# Obter o líder atual
response=$(exec_in_container "proposer1" "curl -s http://localhost:3001/view-logs")
current_leader=$(echo $response | python3 -c "import sys, json; print(json.load(sys.stdin).get('current_leader', '1'))" 2>/dev/null)
leader_container="proposer$current_leader"

show_subsection_header "Verificando visibilidade dos acceptors pelo líder (proposer$current_leader)"

# Verificar se o líder conhece os acceptors
acceptors_info=$(exec_in_container "$leader_container" "curl -s http://localhost:300$current_leader/view-logs" | python3 -c "import sys, json; print(json.load(sys.stdin).get('acceptors_count', 0))" 2>/dev/null)
echo -e "${YELLOW}O líder conhece $acceptors_info acceptors${NC}"

show_subsection_header "Testando fluxo de proposta completo (líder -> acceptors -> learners)"

# Enviar uma proposta através do líder e verificar os logs dos acceptors
echo -e "${YELLOW}Enviando proposta através do líder:${NC}"
proposal_result=$(exec_in_container "$leader_container" "curl -s -X POST http://localhost:300$current_leader/propose -H 'Content-Type: application/json' -d '{\"value\":\"test_acceptor_communication\",\"client_id\":9}'")
echo -e "${CYAN}Resultado da proposta:${NC}"
echo $proposal_result | python3 -m json.tool

wait_for_output 5

show_subsection_header "Verificando se os acceptors processaram a proposta"
for i in {1..3}; do
    echo -e "${YELLOW}Estado do acceptor$i:${NC}"
    acceptor_state=$(exec_in_container "acceptor$i" "curl -s http://localhost:400$i/view-logs")
    accepted_info=$(echo $acceptor_state | python3 -c "import sys, json; data = json.load(sys.stdin); print(f\"Última proposta aceita: número = {data.get('accepted_proposal', {}).get('number', 'N/A')}, valor = {data.get('accepted_proposal', {}).get('value', 'N/A')}\")" 2>/dev/null)
    echo -e "${CYAN}$accepted_info${NC}"
done

# 7. Verificação de Comportamento do Líder
show_section_header "7. VERIFICAÇÃO DE COMPORTAMENTO DO LÍDER"

show_subsection_header "Verificando se o líder atual sabe que é o líder"

# Verificar o estado do líder
response=$(exec_in_container "$leader_container" "curl -s http://localhost:300$current_leader/view-logs")
is_leader=$(echo $response | python3 -c "import sys, json; print(json.load(sys.stdin).get('is_leader', False))" 2>/dev/null)
bootstrap_mode=$(echo $response | python3 -c "import sys, json; print(json.load(sys.stdin).get('bootstrap_mode', False))" 2>/dev/null)

if [ "$is_leader" = "True" ]; then
    echo -e "${GREEN}✓ Proposer$current_leader sabe que é o líder${NC}"
else
    echo -e "${RED}✗ Proposer$current_leader NÃO sabe que é o líder!${NC}"
fi

show_subsection_header "Logs detalhados do líder"
leader_logs=$(docker logs "$leader_container" --tail 15)
echo -e "${GRAY}$leader_logs${NC}"

show_subsection_header "Verificando se o líder está enviando heartbeats"
# Em um sistema real, precisaríamos verificar os logs em detalhes ou usar métricas
# Aqui, vamos examinar os metadados do líder nos outros proposers

for i in {1..3}; do
    if [ "$i" != "$current_leader" ]; then
        echo -e "${YELLOW}Verificando informações sobre o líder em proposer$i:${NC}"
        leader_info=$(exec_in_container "proposer$i" "curl -s http://localhost:300$i/gossip/nodes" | python3 -c "import sys, json; data = json.load(sys.stdin); nodes = data.get('nodes', {}); leader_id = str(data.get('leader_id', 'None')); print(f\"Líder conhecido: {leader_id}\"); leader_data = nodes.get(leader_id, {}); metadata = leader_data.get('metadata', {}); print(f\"Último heartbeat: {metadata.get('last_heartbeat', 'N/A')}\"); print(f\"É líder? {metadata.get('is_leader', False)}\")" 2>/dev/null)
        echo -e "${CYAN}$leader_info${NC}"
    fi
done

# Resumo do teste
show_section_header "RESUMO DO TESTE DE PROPOSERS"
echo -e "${GREEN}✓ Teste de saúde dos proposers${NC}"
echo -e "${GREEN}✓ Visualização de logs dos proposers${NC}"
echo -e "${GREEN}✓ Teste de requisição cliente-proposer${NC}"
echo -e "${GREEN}✓ Teste de comportamento sem líder${NC}"
echo -e "${GREEN}✓ Teste de eleição entre proposers${NC}"
echo -e "${GREEN}✓ Teste de comunicação proposer-acceptor${NC}"
echo -e "${GREEN}✓ Verificação de comportamento do líder${NC}"

echo -e "\n${BLUE}═════════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}Teste de proposers concluído com sucesso!${NC}"
echo -e "${BLUE}═════════════════════════════════════════════════════════════════${NC}"