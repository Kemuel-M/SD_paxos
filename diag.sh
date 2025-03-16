#!/bin/bash

echo "Diagnóstico básico do Paxos no Kubernetes"

# Verificar pods
echo "Verificando pods:"
kubectl get pods -n paxos

# Verificar logs limitados do proposer1
echo "Logs do proposer1 (últimas 10 linhas):"
kubectl logs -n paxos $(kubectl get pods -n paxos -l app=proposer1 -o jsonpath="{.items[0].metadata.name}") --tail=10

# Verificar porta Flask diretamente
echo "Verificando se o Flask está escutando (porta 3001):"
kubectl exec -n paxos $(kubectl get pods -n paxos -l app=proposer1 -o jsonpath="{.items[0].metadata.name}") -- ps -ef | grep python

echo "Verificando o conteúdo da pasta /app:"
kubectl exec -n paxos $(kubectl get pods -n paxos -l app=proposer1 -o jsonpath="{.items[0].metadata.name}") -- ls -la /app

# Verificar se conseguimos fazer uma solicitação para a porta 3001 do proposer1
echo "Testando solicitação HTTP diretamente ao proposer1:"
kubectl exec -n paxos $(kubectl get pods -n paxos -l app=client1 -o jsonpath="{.items[0].metadata.name}") -- curl -s --connect-timeout 3 http://proposer1.paxos.svc.cluster.local:3001/health || echo "Falha na conexão HTTP"

# Verificar DNS 
echo "Testando resolução DNS dentro do cluster:"
kubectl exec -n paxos $(kubectl get pods -n paxos -l app=client1 -o jsonpath="{.items[0].metadata.name}") -- nslookup proposer1.paxos.svc.cluster.local

echo "Diagnóstico concluído"