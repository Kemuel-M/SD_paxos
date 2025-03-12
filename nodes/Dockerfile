FROM python:3.9-slim

WORKDIR /app

# Copiar requirements.txt e instalar dependências
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copiar todos os arquivos Python
COPY *.py .

# Expor portas de aplicação e monitoramento
EXPOSE 3000-6999 8000

# Comando para iniciar o nó
CMD ["python", "main.py"]