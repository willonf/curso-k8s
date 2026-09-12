# Kubernetes multi-node no VirtualBox (Windows)

Cria a mesma infraestrutura do `infra-orbstack`, mas em um ambiente Windows
usando **VirtualBox + Vagrant**. Em vez de máquinas leves do OrbStack, aqui
temos três VMs Ubuntu reais com IPs estáticos numa rede host-only do
VirtualBox (mais previsível e replicável).

> Baseado no `infra-orbstack`, com o mesmo `provision-node.sh` e os mesmos
> passos de CNI (Flannel/Weave). Diferença importante: o kubeadm precisa do
> `controlPlaneEndpoint` fixado, pois a interface NAT das VMs iria mascarar o
> IP real do control-plane (ver `kubeadm-config.yaml`).

## Arquivos

| Arquivo                 | O que faz                                                                  |
|-------------------------|----------------------------------------------------------------------------|
| `Vagrantfile`           | Define as 3 VMs (controlplane, worker1, worker2), rede e provisionamento.  |
| `provision-node.sh`     | Provisiona um nó: kernel, containerd (cgroup=systemd) e kubelet/kubeadm/kubectl. |
| `kubeadm-config.yaml`   | Config do `kubeadm init` (serve para Flannel E Weave).                     |
| `README.md`             | Este arquivo.                                                              |

O `provision-node.sh` corrige os mesmos problemas do script antigo (`script.sh`
do `day-5`): typo `kubeadmn`, repo `apt.kubernetes.io` deprecado (agora
`pkgs.k8s.io`) e containerd com cgroup driver `systemd` (necessário no Ubuntu
24.04 com cgroup v2).

## Pré-requisitos (Windows)

- **VirtualBox** — https://www.virtualbox.org
- **Vagrant** — https://developer.hashicorp.com/vagrant/downloads
- **Cliente SSH** — o Windows 10/11 já traz o OpenSSH Client (Instalar recurso
  opcional). Necessário para `vagrant ssh`.
- **(Opcional) kubectl no Windows** — para controlar o cluster do próprio PC:
  `winget install Kubernetes.kubectl` (ou Chocolatey: `choco install kubernetes-cli`).
- **(Opcional) Git Bash** — recomendado para gerar o kubeconfig e rodar o
  `kubectl` sem problemas de encoding do PowerShell (ver passo 3 do Fluxo 2).

> ⚠️ **Line endings**: salve `provision-node.sh` com **LF** (não CRLF). Editores
> como o VS Code já fazem isso. Um arquivo com CRLF quebra a execução do script
> dentro da VM. Para garantir, rode `git config --global core.autocrlf input`
> antes de clonar.

## Fluxo 1 - criar as VMs

Dentro desta pasta (`virtualbox`), no **PowerShell** ou **Git Bash**:

```bash
vagrant up
```

Na primeira execução o Vagrant baixa a box `bento/ubuntu-24.04` e provisiona
as 3 VMs (leva alguns minutos). Confira o final de cada output: deve exibir as
versões do kubeadm/kubelet/kubectl.

Comandos úteis:

```bash
vagrant status        # estado das VMs (running, etc.)
vagrant provision     # reexecuta o provision-node.sh (ex.: para trocar de série)
vagrant ssh controlplane   # entra na VM
```

> Trocar de série do Kubernetes:
> `$env:K8S_MINOR="v1.37"; vagrant up` (PowerShell) ou
> `K8S_MINOR=v1.37 vagrant up` (Git Bash).

## Arquitetura de rede

| VM           | Hostname      | IP host-only  | Papel        |
|--------------|---------------|---------------|--------------|
| controlplane | controlplane  | 192.168.56.10 | Control-plane |
| worker1      | worker1       | 192.168.56.11 | Worker       |
| worker2      | worker2       | 192.168.56.12 | Worker       |

- **eth0** = NAT (internet, download dos pacotes).
- **eth1** = host-only `192.168.56.0/24` (tráfego entre os nós e com o host).

Todos os nós têm **IP estático**, então o endpoint do control-plane é sempre
`192.168.56.10:6443` (não precisa "conferir o IP" como no OrbStack).

## Fluxo 2 - inicializar o cluster

1) Subir o plano de controle:

```bash
vagrant ssh controlplane
sudo kubeadm init --config /vagrant/kubeadm-config.yaml
```

> O Vagrant sincroniza a pasta do projeto em `/vagrant` dentro da VM, por isso
> o config já está lá. Se quiser apontar para outro arquivo, copie-o para a
> VM manualmente e ajuste o caminho.

Para usar o kubectl dentro do nó:

```bash
mkdir -p $HOME/.kube
sudo cp /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config
kubectl get nodes
```

2) Copiar o kubeconfig para o Windows (controlar tudo do seu PC):

**Git Bash / WSL:**

```bash
mkdir -p ~/.kube
vagrant ssh -c "sudo cat /etc/kubernetes/admin.conf" > ~/.kube/config
kubectl get nodes
```

**PowerShell** (atenção ao encoding — o redirecionamento `>` do PS 5.1 gera
UTF-16 que o kubectl não lê):

```powershell
mkdir ~\.kube
vagrant ssh -c "sudo cat /etc/kubernetes/admin.conf" | Set-Content -Encoding utf8 $HOME\.kube\config
kubectl get nodes
```

> O kubeconfig aponta para `https://192.168.56.10:6443`, visível do Windows via
> rede host-only. Confira com `kubectl cluster-info`.

3) Gerar o comando de join para os workers (token expira em 24h):

```bash
vagrant ssh controlplane "sudo kubeadm token create --print-join-command"
```

Copie a saída (um `kubeadm join 192.168.56.10:6443 --token ... --discovery-token-ca-cert-hash sha256:...`)
e execute com `sudo` em cada worker:

```bash
vagrant ssh worker1 "sudo kubeadm join 192.168.56.10:6443 --token <TOKEN> --discovery-token-ca-cert-hash sha256:<HASH>"
vagrant ssh worker2 "sudo kubeadm join 192.168.56.10:6443 --token <TOKEN> --discovery-token-ca-cert-hash sha256:<HASH>"
```

> O endpoint é o IP estático do control-plane (`192.168.56.10`), definido no
> `Vagrantfile` — não muda mesmo se recriar as VMs.

4) Instalar a rede de pods (CNI). Escolha **uma** das opções abaixo:

**Opção A - Flannel** (recomendado para iniciantes):

```bash
kubectl apply -f https://raw.githubusercontent.com/flannel-io/flannel/master/Documentation/kube-flannel.yml
```

**Opção B - Weave** (com encriptação e suporte a NetworkPolicy):

```bash
kubectl apply -f "https://cloud.weave.works/k8s/net?k8s-version=$(kubectl version | base64 | tr -d '\n')"
```

> O `kubeadm-config.yaml` usa `podSubnet: 10.244.0.0/16`, compatível com os dois.

5) Conferir:

```bash
kubectl get nodes -o wide
kubectl get pods -A
```

Os três nós devem aparecer como `Ready` em seguida.

## Por que precisamos de um plugin CNI?

O Kubernetes **não vem com uma rede de pods (CNI) instalada por padrão**. Sem
um plugin CNI, os pods não conseguem se comunicar entre nós diferentes e o
kubelet fica em estado `NotReady`. O plugin CNI atribui IP a cada pod, roteia o
tráfego entre os nós e gerencia a rede overlay.

Ferramentas como **Kind** já trazem um CNI pré-configurado (o `kindnet`), por
isso você nunca se preocupa com isso. Já com `kubeadm` (como aqui), você escolhe
e instala o CNI manualmente.

## Flannel vs Weave

| Aspecto           | **Flannel**                           | **Weave**                                        |
| ----------------- | ------------------------------------- | ------------------------------------------------ |
| Complexidade      | Simples, foca só em networking        | Mais completo, inclui observabilidade            |
| Criptografia      | Não tem nativamente                   | Encriptação entre peers (sodium)                 |
| Discovery         | Usa etcd ou API server para discovery | Usa gossip protocol (zero-config)                |
| NetworkPolicy     | Não suporta nativamente               | Suporta via Weave Net + rede policies            |
| Multi-hop routing | Não suporta                           | Suporta (pode encaminhar tráfego entre hops)     |
| Performance       | VXLAN overlay, performance sólida     | Overlay com sobrecarga variável                  |
| Manutenção        | Ativamente mantido, amplamente usado  | Menos popular, maintainer reduzida               |
| Uso típico        | Clusters simples, laboratórios        | Clusters que precisam de encriptação ou policies |

**Recomendação**: para laboratório, Flannel é suficiente. Se precisar de
encriptação ou `NetworkPolicy`, Weave (ou Calico) são opções.

## Firewall (Windows)

- **Entre as VMs não há firewall** (o tráfego da rede host-only é interno ao
  VirtualBox), então não é preciso abrir portas para Flannel/Weave entre os nós.
- **Para o kubectl vindo do Windows**: é preciso alcançar `192.168.56.10:6443`
  na interface host-only. Se o Windows Firewall bloquear (primeiro uso), permita
  ou adicione uma regra de entrada para a porta **6443**.
- **SSH do Vagrant** (portas 2200+/forwarded) também passa pelo firewall do
  Windows — permita quando solicitado.

Se um dia for replicar para VMs de nuvem/máquinas reais: abra 6443, 10250 e as
portas da CNI escolhida (Flannel: vxlan 4789/udp; Weave: 6783/6784; Calico:
179/BGP + vxlan).

## Recursos

As 3 VMs usam 2 CPU / 2 GB RAM cada (6 vCPU, 6 GB no total). Para reduzir em
máquinas mais fracas, ajuste `memory` e `cpus` no `Vagrantfile` (ex.: 1024/1).

## Limpeza

```bash
vagrant ssh controlplane -c "sudo kubeadm reset -f"
vagrant ssh worker1      -c "sudo kubeadm reset -f"
vagrant ssh worker2      -c "sudo kubeadm reset -f"
vagrant destroy -f
```

`vagrant destroy -f` remove as VMs; para também apagar a box baixada:
`vagrant box remove bento/ubuntu-24.04`.