#!/usr/bin/env python3
import requests
import sys
import json
import time

def main():
    """CLI para interagir com o cliente Paxos"""
    if len(sys.argv) < 3:
        print("Uso: ./client_cli.py <client_host> <client_port> [command] [args...]")
        print("Comandos disponíveis:")
        print("  write <value>       - Escrever um valor no sistema")
        print("  read                - Ler todos os valores do sistema")
        print("  responses           - Ver respostas recebidas")
        print("  status              - Ver status do cliente")
        return
    
    host = sys.argv[1]
    port = sys.argv[2]
    base_url = f"http://{host}:{port}"
    
    if len(sys.argv) < 4:
        print_help()
        return
    
    command = sys.argv[3]
    
    if command == "write":
        if len(sys.argv) < 5:
            print("Uso: ./client_cli.py <client_host> <client_port> write <value>")
            return
        
        value = sys.argv[4]
        try:
            response = requests.post(f"{base_url}/send", json={"value": value})
            print(json.dumps(response.json(), indent=2))
        except Exception as e:
            print(f"Erro: {e}")
    
    elif command == "read":
        try:
            response = requests.get(f"{base_url}/read")
            data = response.json()
            if "values" in data and data["values"]:
                print("Valores do sistema:")
                for i, value in enumerate(data["values"]):
                    print(f"{i+1}. {value}")
            else:
                print("Nenhum valor encontrado no sistema.")
            print(f"\nTotal: {len(data.get('values', []))} valores")
        except Exception as e:
            print(f"Erro: {e}")
    
    elif command == "responses":
        try:
            response = requests.get(f"{base_url}/get-responses")
            data = response.json()
            if "responses" in data and data["responses"]:
                print("Respostas recebidas:")
                for i, resp in enumerate(data["responses"]):
                    print(f"{i+1}. Valor: {resp['value']} (Learner: {resp['learner_id']}, Recebido em: {resp['received_at']})")
            else:
                print("Nenhuma resposta recebida.")
            print(f"\nTotal: {len(data.get('responses', []))} respostas")
        except Exception as e:
            print(f"Erro: {e}")
    
    elif command == "status":
        try:
            response = requests.get(f"{base_url}/view-logs")
            print(json.dumps(response.json(), indent=2))
        except Exception as e:
            print(f"Erro: {e}")
    
    else:
        print(f"Comando desconhecido: {command}")
        print_help()

def print_help():
    print("Comandos disponíveis:")
    print("  write <value>       - Escrever um valor no sistema")
    print("  read                - Ler todos os valores do sistema")
    print("  responses           - Ver respostas recebidas")
    print("  status              - Ver status do cliente")

if __name__ == "__main__":
    main()