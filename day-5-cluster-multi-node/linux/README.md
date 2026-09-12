# Kubernetes multi-node no Linux (KVM/libvirt + Vagrant)

Cria a mesma infraestrutura do `infra-orbstack` e do `virtualbox`, mas em um
ambiente **Linux nativo**, usando **KVM/libvirt** no lugar do VirtualBox — que é
a melhor alternativa em Linux.

> O `virtualbox/` aqui também funciona em Linux, mas o **KVM/libvirt é
> superior**: hipervisor nativo do kernel (sem camada extra), performance muito
> melhor, boxes menores e integração com o `virt-manager` para acompanhar as VMs.

Baseado no `infra-orbstack`, com o mesmo `provision-node.sh` e os mesmos passos
de CNI (Flannel/Weave). O kubeadm usa `controlPlaneEndpoint` fixado no IP
estático do control-plane (ver `kubeadm-config.yaml`).

## Arquivos

| Arquivo                 | O que faz                                                                  |
|-------------------------|----------------------------------------------------------------------------|
| `Vagrantfile`           | Define as 3 VMs (controlplane, worker1, worker2), rede privada e provisionamento (provider `libvirt`). |
| `provision-node.sh`     | Provisiona um nó: kernel, containerd (cgroup=systemd) e kubelet/kubeadm/kubectl. |
| `kubeadm-config.yaml`   | Config do `kubeadm init` (serve para Flannel E Weave).                     |
| `README.md`             | Este arquivo.                                                              |

## Pré-requisitos (Linux)

1. **KVM habilitado** (virtualização por hardware):

   ```bash
   egrep -c '(vmx|svm)' /proc/cpuinfo    # deve ser > 0
   ls -l /dev/kvm                        # deve existir
   ```

   Se `/dev/kvm` não existir, habilite a virtualização na BIOS/UEFI.

2. **Pacotes do libvirt + QEMU**:

   **Debian/Ubuntu**:

   ```bash
   sudo apt update
   sudo apt install -y qemu-kvm libvirt-daemon-system libvirt-clients virt-manager rsync
   ```

   **Fedora**:

   ```bash
   sudo dnf install -y qemu-kvm libvirt virt-install virt-manager rsync
   ```

   **Arch**:

   ```bash
   sudo pacman -S qemu libvirt virt-manager rsync
   ```

3. **Iniciar o daemon e liberar o seu usuário**:

   ```bash
   sudo systemctl enable --now libvirtd
   sudo usermod -aG libvirt,kvm $USER
   ```

   Relogue (ou reinicie a sessão) para valer os grupos.

4. **Vagrant** — instale o pacote oficial: https://developer.hashicorp.com/vagrant/downloads
   (o `vagrant` do apt costuma ser antigo).

5. **Plugins/libraries para o provider libvirt**:

   ```bash
   sudo apt install -y ruby-dev libvirt-dev libxml2-dev libxslt1-dev build-essential   # Debian/Ubuntu
   # ou em Fedora: sudo dnf install -y ruby-devel libvirt-devel libxml2-devel libxslt-devel gcc make
   vagrant plugin install vagrant-libvirt
   ```

> ⚠️ **Line endings**: salve `provision-node.sh` com **LF** (não CRLF). Se o
> repo foi clonado com `core.autocrlf` ativo no Windows, normalize antes.
> No Linux isso raramente é problema.

## Fluxo 1 - criar as VMs

Dentro desta pasta (`linux`):

```bash
vagrant up
```

Na primeira execução o Vagrant baixa a box `generic/ubuntu2404` (build libvirt)
e provisiona as 3 VMs. Confira o final de cada output: deve exibir as versões
do kubeadm/kubelet/kubectl.

> Se o `vagrant up` pedir a senha de sudo, é o plugin configurando a rede do
> libvirt — autorize normalmente.

Comandos úteis:

```bash
vagrant status              # estado das VMs
vagrant provision           # reexecuta o provision-node.sh
vagrant ssh controlplane    # entra na VM
```

> Trocar de série do Kubernetes: `K8S_MINOR=v1.37 vagrant up`
> (e, se as VMs já existirem, `vagrant provision` para republicar com a nova série).

As VMs aparecem no **virt-manager** (`virt-manager` no terminal) com os nomes
`<pasta>_controlplane`, `<pasta>_worker1` etc.

## Arquitetura de rede

| VM           | Hostname      | IP privado    | Papel        |
|--------------|---------------|---------------|--------------|
| controlplane | controlplane  | 192.168.100.10 | Control-plane |
| worker1      | worker1       | 192.168.100.11 | Worker       |
| worker2      | worker2       | 192.168.100.12 | Worker       |

- **eth0** = rede de gestão/NAT do libvirt (SSH do Vagrant + internet).
- **eth1** = rede privada isolada `192.168.100.0/24` (tráfego entre os nós e
  com o host; não precisa abrir portas de firewall entre as VMs).

Todos os nós têm **IP estático**, então o endpoint do control-plane é sempre
`192.168.100.10:6443`.

## Fluxo 2 - inicializar o cluster

1) Subir o plano de controle:

```bash
vagrant ssh controlplane
sudo kubeadm init --config /vagrant/kubeadm-config.yaml
```

> O Vagrant sincroniza a pasta do projeto em `/vagrant` via **rsync** (re-sincroniza
> com `vagrant reload`). O `kubeadm-config.yaml` já está lá.

Para usar o kubectl dentro do nó:

```bash
mkdir -p $HOME/.kube
sudo cp /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config
kubectl get nodes
```

2) Copiar o kubeconfig para a sua máquina Linux e controlar tudo daqui:

```bash
mkdir -p ~/.kube
vagrant ssh -c "sudo cat /etc/kubernetes/admin.conf" > ~/.kube/config
kubectl get nodes
```

> O kubeconfig aponta para `https://192.168.100.10:6443`, acessível do host via
> rede privada. Confira com `kubectl cluster-info`.

3) Gerar o comando de join para os workers (token expira em 24h):

```bash
vagrant ssh controlplane "sudo kubeadm token create --print-join-command"
```

Copie a saída (um `kubeadm join 192.168.100.10:6443 --token ... --discovery-token-ca-cert-hash sha256:...`)
e execute com `sudo` em cada worker:

```bash
vagrant ssh worker1 "sudo kubeadm join 192.168.100.10:6443 --token <TOKEN> --discovery-token-ca-cert-hash sha256:<HASH>"
vagrant ssh worker2 "sudo kubeadm join 192.168.100.10:6443 --token <TOKEN> --discovery-token-ca-cert-hash sha256:<HASH>"
```

> O endpoint é o IP estático do control-plane (`192.168.100.10`), definido no
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

O Kubernetes **não vem com uma rede de pods (CNI) instalada por padrão**. Sem um
plugin CNI, os pods não conseguem se comunicar entre nós diferentes e o kubelet
fica em estado `NotReady`. O plugin CNI atribui IP a cada pod, roteia o tráfego
entre os nós e gerencia a rede overlay.

Ferramentas como **Kind** já trazem um CNI pré-configurado (o `kindnet`). Já com
`kubeadm` (como aqui), você escolhe e instala o CNI manualmente.

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

## Firewall (Linux)

- **Entre as VMs não há firewall**: o tráfego da rede privada isolada é interno
  ao libvirt — não precisa abrir portas da CNI entre os nós.
- **Para o kubectl vindo do host**: você acessa `192.168.100.10:6443` pelo bridge
  do libvirt (`virbr*`). O `ufw`/`firewalld` normalmente aceita esse tráfego;
  se bloquear, libere a porta **6443** na interface `virbr*`:
  - ufw: `sudo ufw allow in on virbr0 to any port 6443` (ajuste nome do bridge)
  - firewalld: `sudo firewall-cmd --zone=libvirt --add-port=6443/tcp --permanent`
- Se um dia for replicar para VMs de nuvem/máquinas reais: abra 6443, 10250 e as
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

`vagrant destroy -f` remove as VMs. Para limpar também as redes criadas pelo
libvirt, use `virsh net-list --all` e `virsh net-destroy <rede>` se quiser.