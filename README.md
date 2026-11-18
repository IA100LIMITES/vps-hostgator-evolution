# Instalador da Evolution API para a VPS HostGator

Para a VPS da HostGator criada com **Aplicação → n8n**. Entre no console como `root` e rode:

```bash
curl -fsSL https://raw.githubusercontent.com/kaythejoker/vps-hostgator-evolution/main/instalar.sh | bash
```

No fim aparecem o endereço do n8n, o painel da Evolution e a chave da API.
Para ver esses dados de novo: `cat /opt/evolution/LEIA-ME.txt`
