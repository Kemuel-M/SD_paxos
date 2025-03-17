#!/bin/bash

# Cores para output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
GRAY='\033[0;37m'
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

# Verificar docker
if ! command -v docker &> /dev/null; then
    echo -e "${RED}[ERRO] Docker não encontrado. Por favor, instale o Docker para continuar.${NC}"
    exit 1
else
    echo -e "${GREEN}✓ Docker encontrado${NC}"
fi

# Verificar docker-compose
if ! command -v docker-compose &> /dev/null; then
    echo -e "${RED}[ERRO] Docker Compose não encontrado. Por favor, instale o Docker Compose para continuar.${NC}"
    exit 1
else
    echo -e "${GREEN}✓ Docker Compose encontrado: $(docker-compose --version | head -n 1)${NC}"
fi

# Verificar status do Docker
if ! docker info &> /dev/null; then
    echo -e "${RED}[ERRO] Docker não está rodando. Por favor, inicie o serviço Docker antes de continuar.${NC}"
    exit 1
else
    echo -e "${GREEN}✓ Docker está rodando${NC}"
fi

# Verificar se os contêineres estão em execução
if ! docker ps | grep -q "proposer1"; then
    echo -e "${RED}[ERRO] Contêineres do Paxos não encontrados. Execute ./deploy.sh primeiro.${NC}"
    exit 1
else
    echo -e "${GREEN}✓ Contêineres Paxos encontrados${NC}"
fi

# 1. Verificação de serviços e contêineres
show_section_header "VERIFICAÇÃO DE SERVIÇOS E CONTÊINERES"

# Verificar todos os contêineres
show_subsection_header "CONTÊINERES CRIADOS"
run_command "docker-compose ps"

# Obter URLs dos serviços
show_subsection_header "URLs DOS SERVIÇOS"

echo -e "${YELLOW}Obtendo URLs dos serviços...${NC}"

# Mostrar URLs construídas para cada serviço
echo -e "\n${YELLOW}Client1:${NC}"
echo -e "API: ${CYAN}http://localhost:6001${NC}"
echo -e "Monitor: ${CYAN}http://localhost:8009${NC}"

echo -e "\n${YELLOW}Proposer1:${NC}"
echo -e "API: ${CYAN}http://localhost:3001${NC}"
echo -e "Monitor: ${CYAN}http://localhost:8001${NC}"

echo -e "\n${YELLOW}Learner1:${NC}"
echo -e "API: ${CYAN}http://localhost:5001${NC}"
echo -e "Monitor: ${CYAN}http://localhost:8007${NC}"

# 2. Verificação de status dos contêineres
show_section_header "VERIFICAÇÃO DE STATUS DOS CONTÊINERES"

# Verificar status de cada contêiner
show_subsection_header "STATUS DOS CONTÊINERES"
for container in proposer1 proposer2 proposer3 acceptor1 acceptor2 acceptor3 learner1 learner2 client1 client2; do
    echo -e "${YELLOW}Verificando status de $container:${NC}"
    docker inspect -f '{{.State.Status}}' $container
done

# Verificar definição detalhada de um proposer
show_subsection_header "DEFINIÇÃO DETALHADA DO PROPOSER1"
run_command "docker inspect proposer1 | grep -A 10 'State\|NetworkSettings\|HostConfig' | head -n 30"

# 3. Verificação de redes
show_section_header "VERIFICAÇÃO DE REDE"

# Verificar a rede Docker
show_subsection_header "REDES DOCKER DISPONÍVEIS"
run_command "docker network ls | grep -E 'NETWORK|paxos'"

# Detalhar a rede Paxos
show_subsection_header "DETALHES DA REDE PAXOS"
run_command "docker network inspect $(docker network ls | grep paxos | awk '{print $1}') | head -n 30"

# Teste de Conectividade entre Contêineres
show_subsection_header "TESTE DE CONECTIVIDADE ENTRE CONTÊINERES"
echo -e "${YELLOW}Testando conectividade entre contêineres...${NC}"

test_script=$(cat <<EOF
#!/bin/sh
echo "Testando conexões para outros serviços..."
echo "\n=== Teste de DNS para serviços Paxos ==="
for svc in proposer1 proposer2 proposer3 acceptor1 acceptor2 acceptor3 learner1 learner2 client1 client2; do
  echo -n "Resolução de \$svc... "
  if ping -c 1 \$svc > /dev/null 2>&1; then
    echo "✅ OK"
  else
    echo "❌ FALHA"
  fi
done

echo "\n=== Teste de conectividade HTTP ==="
for svc in proposer1 proposer2 proposer3 acceptor1 acceptor2 acceptor3 learner1 learner2 client1 client2; do
  port=8000
  if [[ \$svc == proposer* ]]; then
    port=\$((3000 + \${svc#proposer}))
  elif [[ \$svc == acceptor* ]]; then
    port=\$((4000 + \${svc#acceptor}))
  elif [[ \$svc == learner* ]]; then
    port=\$((5000 + \${svc#learner}))
  elif [[ \$svc == client* ]]; then
    port=\$((6000 + \${svc#client}))
  fi
  
  echo -n "Conectando a \$svc:\$port/health... "
  if wget -q --spider --timeout=2 http://\$svc:\$port/health 2>/dev/null; then
    echo "✅ OK"
  else
    echo "❌ FALHA"
  fi
done
EOF
)

docker exec proposer1 sh -c "$test_script"

# 4. Verificação de logs
show_section_header "VERIFICAÇÃO DE LOGS"

# Função para obter logs condensados
get_condensed_logs() {
    local container=$1
    local lines=${2:-20}
    echo -e "${YELLOW}Últimas $lines linhas de logs para $container:${NC}"
    docker logs $container --tail=$lines
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
leader_check=$(docker exec proposer1 curl -s http://localhost:3001/view-logs)
current_leader=$(echo $leader_check | grep -o '"current_leader":[^,}]*' | cut -d':' -f2 | tr -d '"' 2>/dev/null)

if [ -z "$current_leader" ] || [ "$current_leader" = "null" ] || [ "$current_leader" = "None" ]; then
    echo -e "${RED}✗ Nenhum líder eleito!${NC}"
    
    # Tentar forçar eleição
    echo -e "${YELLOW}Tentando forçar eleição de líder...${NC}"
    election_result=$(docker exec proposer1 curl -s -X POST http://localhost:3001/propose -H 'Content-Type: application/json' -d '{"value":"force_election_test","client_id":9}')
    echo -e "Resultado: $election_result"
    
    # Aguardar um pouco e verificar novamente
    echo -e "${YELLOW}Aguardando 5 segundos para eleição...${NC}"
    sleep 5
    
    leader_check=$(docker exec proposer1 curl -s http://localhost:3001/view-logs)
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
proposal_result=$(docker exec client1 curl -s -X POST http://localhost:6001/send -H 'Content-Type: application/json' -d '{"value":"test_value_'$(date +%s)'"}')
echo -e "Resultado da proposta: $proposal_result"

# Aguardar processamento
echo -e "${YELLOW}Aguardando 3 segundos para processamento...${NC}"
sleep 3

# Verificar se o valor foi aprendido
echo -e "${YELLOW}Verificando valores aprendidos...${NC}"
learned_values=$(docker exec client1 curl -s http://localhost:6001/read)
echo -e "Valores aprendidos: $learned_values"

# 6. Teste de resiliência (opcional)
show_subsection_header "TESTES DE RESILIÊNCIA (OPCIONAL)"
echo -e "${YELLOW}Deseja executar testes de resiliência? [s/N]${NC}"
read -p "> " run_resilience

if [[ "$run_resilience" == "s" || "$run_resilience" == "S" ]]; then
    echo -e "${YELLOW}Simulando falha do contêiner acceptor1...${NC}"
    docker stop acceptor1
    
    echo -e "${YELLOW}Aguardando 5 segundos...${NC}"
    sleep 5
    
    echo -e "${YELLOW}Reiniciando contêiner acceptor1...${NC}"
    docker start acceptor1
    
    echo -e "${YELLOW}Status dos contêineres após simulação de falha:${NC}"
    docker-compose ps
    
    echo -e "${YELLOW}Tentando enviar nova proposta após falha...${NC}"
    docker exec client1 curl -s -X POST http://localhost:6001/send -H 'Content-Type: application/json' -d '{"value":"test_after_failure_'$(date +%s)'"}'
    
    echo -e "${YELLOW}Aguardando processamento...${NC}"
    sleep 3
    
    echo -e "${YELLOW}Verificando valores aprendidos após falha:${NC}"
    docker exec client1 curl -s http://localhost:6001/read
else
    echo -e "${GRAY}Testes de resiliência pulados${NC}"
fi

# 7. Resumo e verificação final
show_section_header "RESUMO DO DIAGNÓSTICO"

# Verificar status final de todos os contêineres
echo -e "${YELLOW}Status final de todos os contêineres:${NC}"
docker-compose ps

# Obter estatísticas dos contêineres
echo -e "\n${YELLOW}Estatísticas dos contêineres:${NC}"
docker stats --no-stream --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.NetIO}}\t{{.BlockIO}}"

# Exibir resumo
total_containers=$(docker-compose ps -q | wc -l)
running_containers=$(docker-compose ps | grep "Up" | wc -l)

echo -e "\n${CYAN}RESUMO DE STATUS:${NC}"
echo -e "Total de contêineres: $total_containers"
echo -e "Contêineres rodando: $running_containers"

if [ "$running_containers" -eq "$total_containers" ]; then
    echo -e "\n${GREEN}✅ TODOS OS CONTÊINERES ESTÃO EM EXECUÇÃO${NC}"
else
    echo -e "\n${RED}⚠️ EXISTEM CONTÊINERES QUE NÃO ESTÃO EM EXECUÇÃO ($running_containers/$total_containers)${NC}"
fi

if [ -n "$current_leader" ] && [ "$current_leader" != "null" ] && [ "$current_leader" != "None" ]; then
    echo -e "${GREEN}✅ SISTEMA TEM UM LÍDER ELEITO (Proposer $current_leader)${NC}"
else
    echo -e "${RED}⚠️ SISTEMA NÃO TEM UM LÍDER ELEITO${NC}"
fi

echo -e "\n${BLUE}═════════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}Diagnóstico do sistema Paxos concluído!${NC}"
echo -e "${BLUE}═════════════════════════════════════════════════════════════════${NC}"