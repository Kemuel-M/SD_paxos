FROM python:3.9-slim

WORKDIR /app

# Copiar requirements.txt
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# O código-fonte é montado como volume para facilitar o desenvolvimento
# Não precisamos copiar os arquivos para a imagem

# Expor portas de aplicação e monitoramento
EXPOSE 3000-6999 8000

# Comando para iniciar o nó (o tipo é determinado pela variável de ambiente NODE_ROLE)
CMD ["python", "main.py"]
