# Sistema Distribuído de Consenso Paxos com Docker Compose

Este projeto implementa um sistema distribuído baseado no algoritmo de consenso Paxos, executando em ambiente Docker Compose. O sistema garante consistência e disponibilidade, mesmo em cenários de falhas parciais de nós.

## Índice

1. [Visão Geral do Sistema](#visão-geral-do-sistema)
2. [Arquitetura](#arquitetura)
3. [Componentes do Sistema](#componentes-do-sistema)
4. [Requisitos de Sistema](#requisitos-de-sistema)
5. [Instalação e Configuração](#instalação-e-configuração)
6. [Guia de Uso](#guia-de-uso)
7. [Scripts Disponíveis](#scripts-disponíveis)
8. [Exemplos de Uso](#exemplos-de-uso)
9. [Solução de Problemas](#solução-de-problemas)
10. [Entendendo o Algoritmo Paxos](#entendendo-o-algoritmo-paxos)

## Visão Geral do Sistema

O sistema Paxos implementa um protocolo de consenso distribuído projetado para garantir que um conjunto de nós concorde sobre valores propostos, mesmo em ambientes com falhas parciais. Esta implementação é composta por:

- **Proposers**: Iniciam propostas e coordenam o processo de consenso
- **Acceptors**: Aceitam ou rejeitam propostas, garantindo consistência
- **Learners**: Aprendem os valores que alcançaram consenso
- **Clients**: Enviam solicitações e recebem respostas

O sistema usa o algoritmo Paxos Completo e inclui um protocolo Gossip para descoberta de nós, permitindo uma operação totalmente descentralizada.

## Arquitetura

### Arquitetura de Software

O sistema é construído com uma arquitetura orientada a objetos em Python:

```
BaseNode (Classe Abstrata)
  ├── Proposer
  ├── Acceptor
  ├── Learner
  └── Client
```

Cada nó expõe uma API REST usando Flask para comunicação, e o estado distribuído é gerenciado pelo protocolo Gossip.

### Arquitetura do Docker Compose

O sistema é implantado em um ambiente Docker Compose com:

```
Docker Network: paxos-network
  ├── Serviços
  │   ├── proposer1, proposer2, proposer3
  │   ├── acceptor1, acceptor2, acceptor3
  │   ├── learner1, learner2
  │   └── client1, client2
  └── Portas Expostas
      ├── Proposers: 3001-3003 (API), 8001-8003 (Monitor)
      ├── Acceptors: 4001-4003 (API), 8004-8006 (Monitor)
      ├── Learners: 5001-5002 (API), 8007-8008 (Monitor)
      └── Clients: 6001-6002 (API), 8009-8010 (Monitor)
```

### Estrutura de Diretórios

```
paxos-system/
├── nodes/                              # Código-fonte dos nós
│   ├── Dockerfile
│   ├── base_node.py                    # Classe base abstrata
│   ├── gossip_protocol.py              # Implementação do protocolo Gossip
│   ├── proposer_node.py                # Implementação do Proposer
│   ├── acceptor_node.py                # Implementação do Acceptor
│   ├── learner_node.py                 # Implementação do Learner
│   ├── client_node.py                  # Implementação do Client
│   ├── main.py                         # Ponto de entrada principal
│   └── requirements.txt                # Dependências Python
├── test/
│   ├── test-paxos.sh                   # Testes funcionais para a rede paxos completa
│   ├── test-client.sh                  # Testes individuais para o Client
│   ├── test-proposer.sh                # Testes individuais para o Proposer
│   ├── test-acceptor.sh                # Testes individuais para o Acceptor
│   ├── test-learner.sh                 # Testes individuais para o Learner
├── docker-compose.yml                  # Configuração do Docker Compose
├── setup-dependencies.sh               # Configuração do ambiente Linux
├── dk-deploy.sh                        # Implantação do sistema
├── dk-run.sh                           # Inicialização da rede Paxos
├── dk-cleanup.sh                       # Limpeza do sistema
├── client.sh                           # Cliente interativo
├── monitor.sh                          # Monitor em tempo real
└── README.md                           # Este arquivo
```

## Componentes do Sistema

### 1. Proposers

Proposers são os nós responsáveis por iniciar propostas e coordenar o processo de consenso.

**Características principais:**
- Recebem solicitações dos clientes
- Iniciam o processo de Paxos com mensagens "prepare"
- Enviam mensagens "accept" quando recebem quórum de "promise"
- Implementam eleição de líder para evitar conflitos
- Apenas o líder eleito pode propor valores
- Usam números de proposta únicos (timestamp * 100 + ID)

**Endpoints API:**
- `/propose`: Recebe propostas de clientes
- `/health`: Verifica saúde do nó
- `/view-logs`: Visualiza logs e estado interno

### 2. Acceptors

Acceptors são os guardiões da consistência, aceitando ou rejeitando propostas.

**Características principais:**
- Respondem a mensagens "prepare" com "promise" ou rejeição
- Aceitam propostas quando o número da proposta é maior ou igual ao prometido
- Mantêm registro do maior número prometido e do valor aceito
- Notificam Learners sobre propostas aceitas
- Formam quórum para decisão (maioria simples)

**Endpoints API:**
- `/prepare`: Recebe mensagens "prepare" dos Proposers
- `/accept`: Recebe mensagens "accept" dos Proposers
- `/health`: Verifica saúde do nó
- `/view-logs`: Visualiza logs e estado interno

### 3. Learners

Learners são responsáveis por aprender e armazenar os valores que alcançaram consenso.

**Características principais:**
- Recebem notificações dos Acceptors sobre valores aceitos
- Determinam quando um valor atingiu consenso (quórum de Acceptors)
- Armazenam valores aprendidos
- Notificam clientes sobre valores aprendidos
- Servem como fonte de leitura para consultas

**Endpoints API:**
- `/learn`: Recebe notificações de valores aceitos
- `/get-values`: Retorna valores aprendidos
- `/health`: Verifica saúde do nó
- `/view-logs`: Visualiza logs e estado interno

### 4. Clients

Clients são interfaces para interação com o sistema.

**Características principais:**
- Enviam solicitações de escrita para Proposers
- Recebem notificações dos Learners
- Consultam Learners para leitura de valores
- Rastreiam respostas recebidas

**Endpoints API:**
- `/send`: Envia valor para o sistema
- `/notify`: Recebe notificação de valor aprendido
- `/read`: Lê valores do sistema
- `/get-responses`: Obtém respostas recebidas
- `/health`: Verifica saúde do nó
- `/view-logs`: Visualiza logs e estado interno

### 5. Protocolo Gossip

O protocolo Gossip é usado para descoberta descentralizada de nós e propagação de metadados.

**Características principais:**
- Permite descoberta automática de nós
- Propaga informações sobre o líder eleito
- Detecta nós inativos
- Distribui metadados entre todos os nós
- Funciona sem ponto único de falha

**Endpoints API:**
- `/gossip`: Recebe atualizações de estado de outros nós
- `/gossip/nodes`: Fornece informações sobre nós conhecidos

## Requisitos de Sistema

### Para ambiente de desenvolvimento:

- Linux, macOS, Windows com WSL, ou Docker Desktop
- Docker Engine 19.03+
- Docker Compose v2.0+
- Python 3.8+ (para desenvolvimento local)
- 4GB+ de RAM disponível
- 2GB+ de espaço em disco

## Instalação e Configuração

### 1. Preparação do Ambiente

```bash
# Clonar o repositório
git clone https://github.com/Kemuel-M/SD_paxos_Kubernets
cd SD_paxos_Kubernets

# Tornar os scripts executáveis
chmod +x *.sh
chmod +x test/*.sh

# Instalar dependências do sistema (opcional, somente para desenvolvimento local)
./setup-dependencies.sh

# Instalar o docker no sistema
./setup-docker.sh
```

### 2. Implantação do Sistema com Docker Compose

```bash
# Construir e iniciar os contêineres
./dk-deploy.sh
```

O script `dk-deploy.sh`:
1. Verifica os pré-requisitos (Docker, Docker Compose)
2. Constrói as imagens Docker dos nós
3. Inicia os contêineres em segundo plano
4. Verifica se todos os contêineres estão funcionando corretamente
5. Exibe URLs de acesso

### 3. Inicialização da Rede Paxos

```bash
# Inicializar o sistema Paxos
./dk-run.sh
```

O script `dk-run.sh`:
1. Verifica se todos os contêineres estão prontos
2. Verifica o status de saúde de cada componente
3. Inicia o processo de eleição de líder
4. Exibe URLs de acesso ao sistema

## Guia de Uso

### 1. Interagindo com o Sistema via Cliente Interativo

```bash
# Executar o cliente interativo
./client.sh
```

O cliente interativo oferece as seguintes opções:
1. **Selecionar cliente**: Escolher entre Client1 e Client2
2. **Enviar valor**: Enviar um valor para o sistema Paxos
3. **Ler valores**: Ler valores armazenados no sistema
4. **Visualizar respostas**: Ver respostas recebidas dos Learners
5. **Ver status do cliente**: Verificar status do cliente atual
6. **Ver status do líder**: Verificar qual Proposer é o líder atual
7. **Enviar diretamente para Proposer**: Enviar valor sem passar pelo Cliente
8. **Ver status do sistema**: Verificar status de todos os componentes

### 2. Monitorando o Sistema em Tempo Real

```bash
# Executar o monitor em tempo real
./monitor.sh
```

Opções do monitor:
```bash
# Monitorar apenas proposers, atualizando a cada 5 segundos
./monitor.sh --proposers --interval 5

# Monitorar apenas acceptors e learners, sem seguir os logs
./monitor.sh --acceptors --learners --no-follow

# Modo verboso com logs do Docker
./monitor.sh --verbose --docker-logs
```

### 3. Limpando o Sistema

```bash
# Parar e remover os contêineres
./dk-cleanup.sh
```

O script perguntará se você deseja remover as imagens e volumes após a limpeza.

## Scripts Disponíveis

### 1. setup-dependencies.sh

**Propósito**: Preparar o ambiente Linux para desenvolvimento.

**Funcionalidades**:
- Instala ferramentas de processamento (jq, curl)
- Instala utilitários de rede
- Configura Python e ambiente virtual
- Instala dependências Python necessárias

**Uso**:
```bash
./setup-dependencies.sh
```

### 2. dk-deploy.sh

**Propósito**: Implantar o sistema Paxos com Docker Compose.

**Funcionalidades**:
- Verifica pré-requisitos (Docker, Docker Compose)
- Constrói as imagens Docker
- Inicia os contêineres em segundo plano
- Verifica o status dos contêineres

**Uso**:
```bash
./dk-deploy.sh
```

### 3. dk-run.sh

**Propósito**: Inicializar a rede Paxos após a implantação.

**Funcionalidades**:
- Verifica o status dos contêineres
- Verifica a saúde de cada componente
- Inicia eleição de líder se necessário
- Exibe URLs de acesso

**Uso**:
```bash
./dk-run.sh
```

### 4. client.sh

**Propósito**: Cliente interativo para o sistema Paxos.

**Funcionalidades**:
- Menu interativo completo
- Operações de leitura e escrita
- Verificação de status
- Envio direto para Proposers

**Uso**:
```bash
./client.sh
```

### 5. monitor.sh

**Propósito**: Monitoramento em tempo real do sistema.

**Funcionalidades**:
- Visualização de logs de todos os componentes
- Filtragem por tipo de nó
- Atualização periódica
- Integração com logs do Docker

**Uso**:
```bash
./monitor.sh [opções]
```

### 6. dk-cleanup.sh

**Propósito**: Limpar recursos Docker.

**Funcionalidades**:
- Para e remove todos os contêineres
- Opção para remover imagens
- Opção para remover volumes
- Limpeza completa do ambiente

**Uso**:
```bash
./dk-cleanup.sh
```

### 7. Scripts de Teste

**Propósito**: Testar componentes individuais e o sistema completo.

**Scripts disponíveis**:
- `test/test-paxos.sh`: Diagnóstico completo do sistema
- `test/test-proposer.sh`: Testes específicos para Proposers
- `test/test-acceptor.sh`: Testes específicos para Acceptors
- `test/test-learner.sh`: Testes específicos para Learners
- `test/test-client.sh`: Testes específicos para Clients

**Uso**:
```bash
# Teste completo do sistema
./test/test-paxos.sh

# Teste específico de proposers
./test/test-proposer.sh
```

## Exemplos de Uso

### Exemplo 1: Inicialização Completa do Sistema

```bash
# 1. Preparar o ambiente (uma única vez)
./setup-dependencies.sh

# 2. Implantar o sistema
./dk-deploy.sh

# 3. Inicializar a rede Paxos
./dk-run.sh
```

### Exemplo 2: Envio e Leitura de Valores

```bash
# 1. Abrir o cliente interativo
./client.sh

# 2. No menu, selecionar opção 2 (Enviar valor)
# 3. Digitar um valor, por exemplo: "teste123"
# 4. No menu, selecionar opção 3 (Ler valores)
# 5. Verificar se o valor enviado aparece na lista
```

### Exemplo 3: Monitoramento Durante Operações

```bash
# Em um terminal, iniciar o monitor
./monitor.sh

# Em outro terminal, usar o cliente para enviar valores
./client.sh

# Observar no monitor como a proposta passa pelos Proposers,
# é aceita pelos Acceptors e finalmente aprendida pelos Learners
```

### Exemplo 4: Testando Tolerância a Falhas

```bash
# 1. Iniciar o monitor
./monitor.sh

# 2. Em outro terminal, parar um acceptor
docker stop acceptor1

# 3. Usar o cliente para enviar um novo valor
./client.sh
# Selecionar opção 2 (Enviar valor)
# Digitar um valor

# 4. Observar no monitor como o sistema ainda alcança consenso
# mesmo com um acceptor faltando

# 5. Restaurar o acceptor
docker start acceptor1
```

## Solução de Problemas

### Problema: Contêineres não iniciam ou ficam em estado de erro

**Sintomas**: Após executar `./dk-deploy.sh`, alguns contêineres não atingem o estado "Up".

**Soluções**:
1. Verificar logs do Docker:
   ```bash
   docker logs proposer1
   ```
2. Verificar se há conflitos de porta:
   ```bash
   netstat -tuln | grep -E '300[1-3]|400[1-3]|500[1-2]|600[1-2]'
   ```
3. Verificar se o Docker tem recursos suficientes:
   ```bash
   docker info | grep -E 'Memory|CPUs'
   ```
4. Reiniciar o Docker:
   ```bash
   sudo service docker restart
   ```

### Problema: Cliente não consegue se conectar aos serviços

**Sintomas**: O script `./client.sh` mostra erros de conexão.

**Soluções**:
1. Verificar se os contêineres estão em execução:
   ```bash
   docker ps | grep paxos
   ```
2. Verificar logs dos contêineres:
   ```bash
   docker logs client1
   ```
3. Verificar a rede Docker:
   ```bash
   docker network inspect paxos-network
   ```
4. Reiniciar o script `dk-run.sh` para verificar o estado do sistema

### Problema: Não há líder eleito

**Sintomas**: O monitor mostra "Sistema sem líder eleito" ou propostas não são aceitas.

**Soluções**:
1. Verificar logs dos proposers:
   ```bash
   docker logs proposer1
   ```
2. Forçar uma nova eleição:
   ```bash
   docker exec proposer1 curl -X POST http://localhost:3001/propose -H 'Content-Type: application/json' -d '{"value":"force_election","client_id":9}'
   ```
3. Verificar se há pelo menos um quórum de acceptors disponível (pelo menos 2 de 3):
   ```bash
   docker ps | grep acceptor
   ```

### Problema: Erros ao executar scripts

**Sintomas**: Scripts mostram erros de permissão ou "command not found".

**Soluções**:
1. Verificar permissões de execução:
   ```bash
   chmod +x *.sh
   ```
2. Verificar se o script está usando a codificação correta:
   ```bash
   dos2unix *.sh  # Se instalado
   ```
3. Verificar o shebang do script:
   ```bash
   head -n 1 *.sh  # Deve mostrar #!/bin/bash
   ```

## Entendendo o Algoritmo Paxos

### Visão Geral do Paxos

O Paxos é um algoritmo de consenso distribuído projetado para alcançar acordo em um valor proposto entre um conjunto de processos, mesmo na presença de falhas. O algoritmo opera em duas fases principais:

### Fase 1: Prepare/Promise

1. Um proposer escolhe um número de proposta `n` e envia uma mensagem `prepare(n)` para um quórum de acceptors.
2. Quando um acceptor recebe `prepare(n)`:
   - Se `n` for maior que qualquer prepare anterior, ele promete não aceitar propostas menores que `n` e responde com um `promise(n)`.
   - O promise inclui o valor de qualquer proposta que o acceptor já tenha aceitado.
3. O proposer coleta promessas de um quórum de acceptors.

### Fase 2: Accept/Accepted

1. Se o proposer recebe promise de um quórum de acceptors, ele envia `accept(n, v)` onde:
   - `n` é o número da proposta
   - `v` é o valor a ser proposto (ou o valor de maior número já aceitado entre as respostas)
2. Quando um acceptor recebe `accept(n, v)`:
   - Se ele não prometeu para um número maior que `n`, ele aceita a proposta e notifica os learners
3. Os learners detectam quando um quórum de acceptors aceitou um valor

### Multi-Paxos e Eleição de Líder

Nossa implementação usa uma variação do Paxos chamada Multi-Paxos com eleição de líder:

1. Na inicialização, os proposers competem pela liderança
2. O primeiro proposer a obter um quórum de promessas se torna líder
3. O líder pode propor valores diretamente (pulando a fase Prepare)
4. Se o líder falhar, uma nova eleição ocorre automaticamente
5. O protocolo Gossip propaga informações sobre o líder atual

---

Para mais informações sobre o algoritmo Paxos, consulte o paper original de Leslie Lamport, "Paxos Made Simple".