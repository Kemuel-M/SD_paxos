FROM python:3.9-slim

WORKDIR /app

# Instalar curl e outras ferramentas úteis para diagnóstico
RUN apt-get update && \
    apt-get install -y \
    curl \
    dnsutils \
    iputils-ping \
    net-tools \
    procps \
    wget && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Copiar requirements.txt e instalar dependências
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt gunicorn

# Copiar todos os arquivos Python
COPY *.py .

# Expor portas para proposer, acceptor, learner, client e monitoramento
# Proposers (3001-3003)
# Acceptors (4001-4003)
# Learners (5001-5002)
# Clients (6001-6002)
# Monitor (8000)
# EXPOSE 3000-6999 8000
# Apenas as portas específicas que você realmente precisa:
EXPOSE 3001 3002 3003
EXPOSE 4001 4002 4003
EXPOSE 5001 5002
EXPOSE 6001 6002
EXPOSE 8000

# Healthcheck para verificar se o serviço está funcionando
HEALTHCHECK --interval=10s --timeout=3s --start-period=30s --retries=3 \
    CMD curl -f http://localhost:${PORT:-8000}/health || exit 1

# Comando para iniciar o nó
CMD ["python", "main.py"]