# Sistema Distribuído Paxos com Docker Swarm

Este projeto implementa um sistema distribuído baseado no algoritmo de consenso Paxos usando Docker Swarm.

## Visão Geral

O sistema é composto por vários tipos de nós, cada um desempenhando um papel específico no algoritmo Paxos:

- **Proposers (3)**: Iniciam propostas e coordenam o processo de consenso. Um deles é eleito como líder.
- **Acceptors (3)**: Garantem o consenso, aceitando ou rejeitando propostas.
- **Learners (2)**: Aprendem os valores escolhidos após o consenso e notificam os clientes.
- **Clients (2)**: Enviam requisições para o sistema e recebem respostas.
- **Discovery Service (1)**: Coordena a descoberta de nós e a eleição de líder.

## Características Implementadas

- **Eleição de Líder**: Mecanismo para eleição de líder entre os proposers.
- **Consenso Distribuído**: Implementação do algoritmo Paxos para garantir consenso.
- **Descoberta Dinâmica**: Serviço de descoberta para localização de nós.
- **Tolerância a Falhas**: O sistema continua operando mesmo com a falha de alguns nós.
- **Monitoramento**: Interface para visualização de logs e estado do sistema.
- **Cliente Interativo**: CLI para interagir com o sistema.

## Requisitos

- Docker (versão 19.03+)
- Docker Compose
- Python 3.6+

## Instalação e Execução

1. Clone o repositório:

```bash
git clone <repositório> paxos-system
cd paxos-system
```

2. Execute o script de inicialização:

```bash
chmod +x run.sh
chmod +x run.sh monitor.sh test-scenario.sh client/client_cli.py
./run.sh
```

O script irá:
- Inicializar o Docker Swarm (se necessário)
- Construir as imagens Docker
- Iniciar todos os serviços
- Mostrar informações sobre como acessar e interagir com o sistema

## Interagindo com o Sistema

### Usando o CLI do Cliente

O script `client_cli.py` permite interagir com o sistema:

```bash
# Escrever um valor
./client/client_cli.py localhost 6001 write "novo valor"

# Ler valores
./client/client_cli.py localhost 6001 read

# Ver respostas recebidas
./client/client_cli.py localhost 6001 responses

# Ver status do cliente
./client/client_cli.py localhost 6001 status
```

### Monitorando o Sistema

Use o script de monitoramento para visualizar o estado do sistema em tempo real:

```bash
chmod +x monitor.sh
./monitor.sh
```

### Executando Cenários de Teste

Um script de teste de cenário está disponível para demonstrar as funcionalidades do sistema:

```bash
chmod +x test-scenario.sh
./test-scenario.sh
```

## Acessando Logs e Estado

Cada nó expõe uma interface web para visualização de logs e estado:

- Discovery: http://localhost:8000/view-logs
- Proposer 1: http://localhost:8001/view-logs
- Proposer 2: http://localhost:8002/view-logs
- Proposer 3: http://localhost:8003/view-logs
- Acceptor 1: http://localhost:8004/view-logs
- Acceptor 2: http://localhost:8005/view-logs
- Acceptor 3: http://localhost:8006/view-logs
- Learner 1: http://localhost:8007/view-logs
- Learner 2: http://localhost:8008/view-logs
- Client 1: http://localhost:8009/view-logs
- Client 2: http://localhost:8010/view-logs

## Parando o Sistema

Para parar o sistema, execute:

```bash
docker stack rm paxos
```

## Arquitetura

```
+----------+    +----------+     +----------+
|          |    |          |     |          |
| Client 1 |    | Client 2 |     | Discovery|
|          |    |          |     |          |
+----+-----+    +-----+----+     +-----+----+
     |                |                |
     +----------------+----------------+
                      |
+---------------------+---------------------+
|                                           |
|                  NETWORK                  |
|                                           |
+---+-------------------+-------------------+
    |                   |                   |
+---+-------+    +-----+-----+    +--------+--+
|           |    |           |    |           |
| Proposers |    | Acceptors |    | Learners  |
| (1,2,3)   |    | (1,2,3)   |    | (1,2)     |
|           |    |           |    |           |
+-----------+    +-----------+    +-----------+
```

## Fluxo de Consenso

1. Cliente envia valor para um Proposer (preferencialmente o líder)
2. Proposer inicia fase Prepare do Paxos com os Acceptors
3. Acceptors respondem com Promise (se puderem prometer)
4. Proposer inicia fase Accept com o valor proposto
5. Acceptors aceitam o valor (se consistente com promessas)
6. Acceptors notificam os Learners sobre o valor aceito
7. Learners confirmam para o Cliente que o valor foi aprendido

## Detalhes Técnicos

### Mecanismo de Eleição de Líder

- Baseado no próprio algoritmo Paxos
- Cada proposer tem um ID único
- Proposta numerada como: contador * 100 + ID
- Quórum de acceptors para eleger um líder
- Heartbeats para detectar falhas

### Tolerância a Falhas

- O sistema pode continuar operando mesmo com a falha de alguns nós
- Quórum para decisões: mais da metade dos acceptors
- Reeleição automática de líder em caso de falha
