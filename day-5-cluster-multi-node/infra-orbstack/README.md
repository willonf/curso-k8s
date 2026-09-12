# Kubernetes multi-node no OrbStack

## Arquivos


| Arquivo               | O que faz                                                        |
| --------------------- | ---------------------------------------------------------------- |
| `provision-node.sh`   | Provisiona um nó (rodado com `sudo` dentro da máquina).          |
| `apply.sh`            | Aplica o `provision-node.sh` em máquinas OrbStack já existentes. |
| `kubeadm-config.yaml` | Config do `kubeadm init` (aponta para as variantes de CNI).      |


---

## Fluxo A - provisionar máquinas já existentes

As máquinas `controlplane`, `worker1` e `worker2` já existem, então:

```bash
cd infra-orbstack
./apply.sh controlplane worker1 worker2
```

Isso faz `orb push` (o destino e sempre relativo ao home do usuario Linux, por isso o script usa `~/provision-node.sh`) e executa com `sudo`. Confira o final de cada saida: deve exibir as versoes do kubeadm/kubelet/kubectl.

> Trocar de serie do Kubernetes: `K8S_MINOR=v1.37 ./apply.sh controlplane worker1 worker2`

---



## Fluxo B - recriar as máquinas do zero (cloud-init)

> Se as máquinas já existirem, use o Fluxo A (não precisa apagar e recriar).

O `provision-node.sh` tambem serve como user-data do OrbStack e roda sozinho no primeiro boot:

```bash
orb create ubuntu controlplane -c provision-node.sh
orb create ubuntu worker1      -c provision-node.sh
orb create ubuntu worker2      -c provision-node.sh
```

---



## Fluxo C - inicializar o cluster

1. Subir o plano de controle (no `controlplane`):

```bash
orb -m controlplane shell
sudo kubeadm init --config kubeadm-config.yaml
```

Para usar o kubectl dentro do nó:

```bash
mkdir -p $HOME/.kube
sudo cp /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config
kubectl get nodes
```

1. Copiar o kubeconfig para o macOS se quiser controlar tudo pelo seu PC:

```bash
mkdir -p ~/.kube
orb -m controlplane sudo cat /etc/kubernetes/admin.conf > ~/.kube/config
kubectl get nodes
```

> O host no kubeconfig aponta para o IP interno do control-plane, visível do macOS. Recomendo conferir antes de usar: `kubectl cluster-info`.

1. Gerar o comando de join para os workers (token expira em 24h):

```bash
orb -m controlplane sudo kubeadm token create --print-join-command
```

Copie a saida (um `kubeadm join <ip>:6443 --token ... --discovery-token-ca-cert-hash ...`)
e execute com `sudo` em cada worker:

```bash
orb -m worker1 shell
sudo kubeadm join 192.168.139.35:6443 --token <TOKEN> --discovery-token-ca-cert-hash sha256:<HASH>
```

> O endpoint `<ip>` e o IP do control-plane — confira SEMPRE em `orb list`, pois recriar máquinas pode mudar os IPs.

1. Instalar a rede de pods (CNI). Escolha **uma** das opcoes abaixo:

**Opcao A - Flannel** (recomendado para iniciantes):

```bash
kubectl apply -f https://raw.githubusercontent.com/flannel-io/flannel/master/Documentation/kube-flannel.yml
```

**Opcao B - Weave** (com encriptacao e suporte a NetworkPolicy):

```bash
kubectl apply -f https://cloud.weave.works/k8s/net?k8s-version=$(kubectl version | base64 | tr -d '\n')
```

> Para usar Weave, certifique-se de que o `kubeadm-config.yaml` usa`podSubnet: 10.244.0.0/16` (compativel com Weave).

1. Conferir:

```bash
kubectl get nodes -o wide
kubectl get pods -A
```

Os três nós devem aparecer como `Ready` em seguida.

## Firewall

Nas máquinas OrbStack não há firewall entre os nós (`ufw` ausente, sem regras de `iptables`), então não é preciso abrir portas. Se um dia for replicar para VMs de nuvem/máquinas reais: abra 6443, 10250 e as portas da CNI escolhida (Flannel: vxlan; Weave: 6783/6784; Calico: 179/BGP + vxlan).

## Limpeza

```bash
orb -m controlplane shell && sudo kubeadm reset -f
orb -m worker1 shell && sudo kubeadm reset -f
orb -m worker2 shell && sudo kubeadm reset -f
```

Para apagar as máquinas: `orb delete controlplane worker1 worker2`.

---



## Por que precisamos de um plugin CNI?

O Kubernetes **não vem com uma rede de pods (CNI) instalada por padrão**. Sem um plugin CNI, os pods não conseguem se comunicar entre nós diferentes e o kubelet fica em estado `NotReady`.

O que um plugin CNI faz:

- Atribui um IP a cada pod
- Permite que pods em nós diferentes se comuniquem entre si
- Gerencia o roteamento do trafego entre pods

Para comparar: ferramentas como **Kind** já trazem um CNI pré-configurado (usa o `kindnet`), por isso você nunca precisa se preocupar com isso ao criar um cluster com Kind. Já com `kubeadm`, você monta o cluster manualmente e precisa escolher e instalar o CNI manualmente.

## Flannel vs Weave


| Aspecto           | **Flannel**                           | **Weave**                                        |
| ----------------- | ------------------------------------- | ------------------------------------------------ |
| Complexidade      | Simples, foca só em networking        | Mais completo, inclui observabilidade            |
| Criptografia      | Não tem nativamente                   | Encriptação entre peers (sodium)                 |
| Discovery         | Usa etcd ou API server para discovery | Usa gossip protocol (zero-config)                |
| NetworkPolicy     | Não suporta nativamente               | Suporta via Weave Net + rede policies            |
| Multi-hop routing | Não suporta                           | Suporta (pode encaminhar trafego entre hops)     |
| Performance       | VXLAN overlay, performance sólida     | Overlay com sobrecarga variavel                  |
| Manutencao        | Ativamente mantido, amplamente usado  | Menos popular, maintainer reduzida               |
| Uso tipico        | Clusters simples, laboratorios        | Clusters que precisam de encriptacao ou policies |


**Recomendacao**: Para um cluster Kind ou laboratorio, Flannel e suficiente. Se precisar de encriptacao ou `NetworkPolicy`, Weave (ou Calico) sao opções.