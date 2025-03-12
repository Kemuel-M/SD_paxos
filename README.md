# Sistema Distribuído Paxos com Gossip Protocol e Arquitetura OO

Este projeto implementa um sistema distribuído baseado no algoritmo de consenso Paxos usando Gossip Protocol para comunicação descentralizada e uma arquitetura orientada a objetos para reutilização de código.

## Arquitetura

O sistema foi projetado seguindo os princípios da orientação a objetos, com uma classe base abstrata `BaseNode` que implementa funcionalidades comuns a todos os tipos de nós. Cada tipo de nó específico (`Proposer`, `Acceptor`, `Learner`, `Client`) herda desta classe base e adiciona suas funcionalidades específicas.

### Componentes

- **BaseNode**: Classe base abstrata que implementa funcionalidades comuns a todos os nós.
- **Gossip Protocol**: Implementação do protocolo de gossip para descoberta descentralizada de nós.
- **Proposer**: Nó responsável por propor valores e coordenar o consenso.
- **Acceptor**: Nó responsável por aceitar ou rejeitar propostas.
- **Learner**: Nó responsável por aprender valores acordados e notificar clientes.
- **Client**: Nó responsável por enviar solicitações ao sistema e receber resultados.

### Fluxo de Comunicação

1. Descoberta de nós via Gossip Protocol
2. Eleição descentralizada de líder
3. Clientes enviam valores para o líder atual
4. Proposers iniciam o protocolo Paxos
5. Acceptors aceitam ou rejeitam propostas
6. Learners aprendem valores aceitos
7. Clients são notificados dos resultados

## Vantagens da Arquitetura

### Vantagens do Gossip Protocol

- **Descentralização**: Nenhum ponto único de falha
- **Resiliência**: O sistema continua funcionando mesmo com falha de vários nós
- **Escalabilidade**: A comunicação é distribuída entre todos os nós
- **Recuperação Automática**: Detecção de nós inativos e recuperação automática

### Vantagens da Arquitetura OO

- **Reutilização de Código**: Funcionalidades comuns implementadas apenas uma vez
- **Manutenibilidade**: Mais fácil de manter e estender
- **Encapsulamento**: Cada tipo de nó encapsula seu comportamento específico
- **Polimorfismo**: Tratamento uniforme de todos os tipos de nós

## Requisitos

- Docker (versão 19.03+)
- Docker Swarm mode ativo
- Python 3.9+ (para desenvolvimento e testes locais)

## Instalação e Execução

1. **Clone o repositório**:

```bash
git clone <url-do-repositorio> paxos-system
cd paxos-system
```

2. **Execute o script de inicialização**:

```bash
chmod +x run.sh
./run.sh
```

Este script irá:
- Inicializar o Docker Swarm (se necessário)
- Construir a imagem Docker do nó Paxos
- Iniciar todos os serviços (proposers, acceptors, learners, clients)
- Verificar se todos os serviços iniciaram corretamente

3. **Interagir com o sistema**:

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

## Estrutura de Arquivos

```
├── base_node.py            # Classe base abstrata para todos os nós
├── gossip_protocol.py      # Implementação do protocolo Gossip
├── proposer_node.py        # Implementação do nó Proposer
├── acceptor_node.py        # Implementação do nó Acceptor
├── learner_node.py         # Implementação do nó Learner
├── client_node.py          # Implementação do nó Client
├── main.py                 # Ponto de entrada principal
├── Dockerfile              # Dockerfile único para todos os tipos de nós
├── docker-compose.yml      # Configuração do Docker Compose
├── requirements.txt        # Dependências Python
├── run.sh                  # Script de inicialização
└── client/
    └── client_cli.py       # Cliente de linha de comando
```

## Monitoramento

Cada nó expõe uma interface web para visualização de logs e estado em `/view-logs`:

- Proposer1: http://localhost:8001/view-logs
- Proposer2: http://localhost:8002/view-logs
- Proposer3: http://localhost:8003/view-logs
- Acceptor1: http://localhost:8004/view-logs
- Acceptor2: http://localhost:8005/view-logs
- Acceptor3: http://localhost:8006/view-logs
- Learner1: http://localhost:8007/view-logs
- Learner2: http://localhost:8008/view-logs
- Client1: http://localhost:8009/view-logs
- Client2: http://localhost:8010/view-logs

## Parando o Sistema

Para parar o sistema, execute:

```bash
docker stack rm paxos
```

## Contribuindo

1. Faça um fork do repositório
2. Crie sua branch de feature (`git checkout -b feature/nova-funcionalidade`)
3. Faça commit das suas mudanças (`git commit -am 'Adiciona nova funcionalidade'`)
4. Faça push para a branch (`git push origin feature/nova-funcionalidade`)
5. Abra um Pull Request
