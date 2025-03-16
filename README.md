# Sistema Distribuído de Consenso Paxos em Kubernetes

Este projeto implementa um sistema distribuído baseado no algoritmo de consenso Paxos, executando em um ambiente Kubernetes. O sistema garante consistência e disponibilidade, mesmo em cenários de falhas parciais de nós.

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

### Arquitetura do Kubernetes

O sistema é implantado em um cluster Kubernetes com:

```
Namespace "paxos"
  ├── Deployments
  │   ├── proposer1, proposer2, proposer3
  │   ├── acceptor1, acceptor2, acceptor3
  │   ├── learner1, learner2
  │   └── client1, client2
  ├── Services
  │   ├── proposer-services
  │   ├── acceptor-services
  │   ├── learner-services
  │   └── client-services
  └── NodePort Services (para acesso externo)
```

### Estrutura de Diretórios

```
paxos-system/
├── nodes/                  # Código-fonte dos nós
│   ├── Dockerfile
│   ├── base_node.py        # Classe base abstrata
│   ├── gossip_protocol.py  # Implementação do protocolo Gossip
│   ├── proposer_node.py    # Implementação do Proposer
│   ├── acceptor_node.py    # Implementação do Acceptor
│   ├── learner_node.py     # Implementação do Learner
│   ├── client_node.py      # Implementação do Client
│   ├── main.py             # Ponto de entrada principal
│   └── requirements.txt    # Dependências Python
├── k8s/                    # Manifestos Kubernetes
│   ├── 00-namespace.yaml
│   ├── 01-configmap.yaml
│   ├── 02-proposers.yaml
│   ├── 03-acceptors.yaml
│   ├── 04-learners.yaml
│   ├── 05-clients.yaml
│   ├── 06-ingress.yaml
│   └── 07-nodeport-services.yaml
├── setup-dependencies.sh
├── setup-kubernetes-wsl.sh # Configuração do ambiente no WSL
├── deploy-paxos-k8s.sh     # Implantação do sistema no Kubernetes
├── run.sh                  # Inicialização da rede Paxos
├── paxos-client.sh         # Cliente interativo
├── monitor.sh              # Monitor em tempo real
├── cleanup-paxos-k8s.sh    # Limpeza do sistema
└── README.md               # Este arquivo
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

### Para ambiente de desenvolvimento (WSL/Ubuntu):

- Windows 10/11 com WSL2 habilitado
- Ubuntu 20.04 LTS ou superior no WSL
- Docker Engine 19.03+
- Kubernetes (via Minikube)
- Python 3.8+
- 4GB+ de RAM disponível
- 10GB+ de espaço em disco

### Para ambiente de produção:

- Cluster Kubernetes v1.18+
- Registro de contêineres (Docker Registry)
- Sistema de armazenamento persistente
- Balanceador de carga externo (opcional)
- Monitoramento e logging (recomendado)

## Instalação e Configuração

### 1. Preparação do Ambiente WSL

```bash
# Torne o script executável
chmod +x setup-kubernetes-wsl.sh

# Execute o script de preparação
./setup-kubernetes-wsl.sh

# Reinicie o WSL após a instalação
# No PowerShell do Windows:
wsl --shutdown
# Reabra seu terminal WSL
```

O script `setup-kubernetes-wsl.sh` instala:
- Docker
- kubectl
- Minikube
- Dependências necessárias

### 2. Inicialização do Cluster Minikube

```bash
# Inicie o cluster Minikube
minikube start --driver=docker

# Verifique o status
minikube status
```

### 3. Implantação do Sistema no Kubernetes

```bash
# Torne o script executável
chmod +x deploy-paxos-k8s.sh

# Execute o script de implantação
./deploy-paxos-k8s.sh
```

O script `deploy-paxos-k8s.sh`:
1. Constrói a imagem Docker do nó Paxos
2. Cria o namespace "paxos"
3. Aplica todos os manifestos Kubernetes
4. Configura serviços NodePort para acesso externo
5. Aguarda a inicialização dos pods

### 4. Inicialização da Rede Paxos

```bash
# Torne o script executável
chmod +x run.sh

# Execute o script de inicialização
./run.sh
```

O script `run.sh`:
1. Verifica se todos os pods estão prontos
2. Inicia o processo de eleição de líder
3. Verifica a saúde de todos os componentes
4. Exibe URLs de acesso

## Guia de Uso

### 1. Interagindo com o Sistema via Cliente Interativo

```bash
# Torne o script executável
chmod +x paxos-client.sh

# Execute o cliente interativo
./paxos-client.sh
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
# Torne o script executável
chmod +x monitor.sh

# Execute o monitor em tempo real
./monitor.sh
```

Opções do monitor:
```bash
# Monitorar apenas proposers, atualizando a cada 5 segundos
./monitor.sh --proposers --interval 5

# Monitorar apenas acceptors e learners, sem seguir os logs
./monitor.sh --acceptors --learners --no-follow

# Modo verboso com logs do Kubernetes
./monitor.sh --verbose --kubectl-logs
```

### 3. Limpando o Sistema

```bash
# Torne o script executável
chmod +x cleanup-paxos-k8s.sh

# Execute o script de limpeza
./cleanup-paxos-k8s.sh
```

O script perguntará se você deseja parar ou excluir o cluster Minikube após a limpeza.

## Scripts Disponíveis

### 1. setup-kubernetes-wsl.sh

**Propósito**: Preparar o ambiente Kubernetes no WSL.

**Funcionalidades**:
- Instala Docker, kubectl, Minikube
- Configura permissões e grupos de usuário
- Prepara o ambiente para execução do Kubernetes no WSL

**Uso**:
```bash
./setup-kubernetes-wsl.sh
```

### 2. deploy-paxos-k8s.sh

**Propósito**: Implantar o sistema Paxos no Kubernetes.

**Funcionalidades**:
- Verifica pré-requisitos (Docker, kubectl, Minikube)
- Constrói a imagem Docker para os nós
- Aplica manifestos Kubernetes
- Configura serviços e acessos

**Uso**:
```bash
./deploy-paxos-k8s.sh
```

### 3. run.sh

**Propósito**: Inicializar a rede Paxos após a implantação no Kubernetes.

**Funcionalidades**:
- Verifica status dos pods
- Inicia eleição de líder
- Verifica a saúde do sistema
- Exibe URLs de acesso

**Uso**:
```bash
./run.sh
```

### 4. paxos-client.sh

**Propósito**: Cliente interativo para o sistema Paxos.

**Funcionalidades**:
- Menu interativo completo
- Operações de leitura e escrita
- Verificação de status
- Envio direto para Proposers

**Uso**:
```bash
./paxos-client.sh
```

### 5. monitor.sh

**Propósito**: Monitoramento em tempo real do sistema.

**Funcionalidades**:
- Visualização de logs de todos os componentes
- Filtragem por tipo de nó
- Atualização periódica
- Integração com logs do Kubernetes

**Uso**:
```bash
./monitor.sh [opções]
```

### 6. cleanup-paxos-k8s.sh

**Propósito**: Limpar recursos Kubernetes.

**Funcionalidades**:
- Remove todos os recursos na ordem correta
- Opção para parar ou excluir o cluster Minikube
- Limpeza completa do ambiente

**Uso**:
```bash
./cleanup-paxos-k8s.sh
```

## Exemplos de Uso

### Exemplo 1: Inicialização Completa do Sistema

```bash
# 1. Preparar o ambiente (uma única vez)
./setup-kubernetes-wsl.sh

# Reiniciar WSL
# No PowerShell: wsl --shutdown
# Reabrir terminal WSL

# 2. Iniciar o cluster Minikube
minikube start --driver=docker

# 3. Implantar o sistema
./deploy-paxos-k8s.sh

# 4. Inicializar a rede Paxos
./run.sh
```

### Exemplo 2: Envio e Leitura de Valores

```bash
# 1. Abrir o cliente interativo
./paxos-client.sh

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
./paxos-client.sh

# Observar no monitor como a proposta passa pelos Proposers,
# é aceita pelos Acceptors e finalmente aprendida pelos Learners
```

### Exemplo 4: Testando Tolerância a Falhas

```bash
# 1. Iniciar o monitor
./monitor.sh

# 2. Em outro terminal, excluir um acceptor
kubectl scale deployment acceptor1 -n paxos --replicas=0

# 3. Usar o cliente para enviar um novo valor
./paxos-client.sh
# Selecionar opção 2 (Enviar valor)
# Digitar um valor

# 4. Observar no monitor como o sistema ainda alcança consenso
# mesmo com um acceptor faltando

# 5. Restaurar o acceptor
kubectl scale deployment acceptor1 -n paxos --replicas=1
```

## Solução de Problemas

### Problema: Pods não iniciam ou ficam em estado pendente

**Sintomas**: Após executar `./deploy-paxos-k8s.sh`, alguns pods não atingem o estado "Running".

**Soluções**:
1. Verificar eventos do Kubernetes:
   ```bash
   kubectl get events -n paxos
   ```
2. Verificar detalhes do pod:
   ```bash
   kubectl describe pod <nome-do-pod> -n paxos
   ```
3. Verificar logs do pod:
   ```bash
   kubectl logs <nome-do-pod> -n paxos
   ```
4. Verificar recursos disponíveis no Minikube:
   ```bash
   minikube ssh -- free -h
   minikube ssh -- df -h
   ```

### Problema: Cliente não consegue se conectar aos serviços

**Sintomas**: O script `./paxos-client.sh` mostra erros de conexão.

**Soluções**:
1. Verificar se os pods estão em execução:
   ```bash
   kubectl get pods -n paxos
   ```
2. Verificar detalhes dos serviços:
   ```bash
   kubectl get services -n paxos
   ```
3. Verificar encaminhamento de portas do Minikube:
   ```bash
   minikube service list -n paxos
   ```
4. Reiniciar o script `run.sh` para verificar o estado do sistema

### Problema: Não há líder eleito

**Sintomas**: O monitor mostra "Sistema sem líder eleito" ou propostas não são aceitas.

**Soluções**:
1. Verificar logs dos proposers:
   ```bash
   kubectl logs -l app=proposer1 -n paxos
   ```
2. Reiniciar o processo de eleição:
   ```bash
   ./run.sh
   ```
3. Verificar se há pelo menos um quórum de acceptors disponível (pelo menos 2 de 3):
   ```bash
   kubectl get pods -n paxos -l role=acceptor
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