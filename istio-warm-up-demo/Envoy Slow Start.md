在 Mesh 中支持预热

### 现状

由于 Istio 和 Envoy 最初并不支持预热，在接入 Mesh 时，我们为了实现类似预热的效果，对需要预热的应用设置使用最小连接数的负载均衡器，这种方式一般来说效果还可以，而且尽量少的设置配置项，让运行过程中负载均衡器根据连接数情况自适应的分发流量。但是最近遇到的场景来看，有些情况下这种方式仍然会带来一些客户端报错以及达不到预热效果的情况，比如客户端设置了较短的超时时间，超时后连接断开，那么因为负载均衡的算法是最小连接数，又会有新的请求被分发到刚启动的实例。

为了缓解这种情况，我们对 ServiceEntry 的 endpoint 设置权重，来调整刚启动后处于预热期间的实例的权重。

这种方式可行，但是一方面 soa operator 需要额外的逻辑来处理，另一方面因为实例权重有变更，istio 需要额外做一些推送。

### Envoy 慢启动模式

Envoy 的较新版本开始支持[慢启动模式](https://www.envoyproxy.io/docs/envoy/latest/intro/arch_overview/upstream/load_balancing/slow_start#arch-overview-load-balancing-slow-start)。这一种影响 upstream endpoints **负载均衡权重**的机制，可以针对每个upstream cluster 进行配置。目前 Envoy 的慢启动模式仅支持 [Round Robin](https://www.envoyproxy.io/docs/envoy/latest/api-v3/config/cluster/v3/cluster.proto#envoy-v3-api-field-config-cluster-v3-cluster-roundrobinlbconfig-slow-start-config) 和 [Least Request](https://www.envoyproxy.io/docs/envoy/latest/api-v3/config/cluster/v3/cluster.proto#envoy-v3-api-field-config-cluster-v3-cluster-leastrequestlbconfig-slow-start-config) 这两种负载均衡器。

Envoy 慢启动相关的配置项如下

```json
{
  "slow_start_window": {...},
  "aggression": {...},
  "min_weight_percent": {...}
}
```

**slow_start_window**

这个配置用来控制预热持续时间

**aggression**

用来控制预热期间流量增长的速度，默认值是 1.0，表示预热期间流量线性增长。通过调整该参数，可以得到不同的流量增长曲线。

**min_weight_percent**

用来设置初始权重的最小比例

用来计算权重的公式是

![slow_start_formula](/Users/zhongyuan/github/masquee/misc/istio-warm-up-demo/slow_start_formula.png)

下面是 Envoy 官网给出的不同的 aggression 值与权重变化关系的对照图

![slow_start_aggression](/Users/zhongyuan/github/masquee/misc/istio-warm-up-demo/slow_start_aggression.png)



Endpoint 进入慢启动模式的条件

- 如果 cluster 没有配置**主动健康检测**（[active health checking](https://www.envoyproxy.io/docs/envoy/latest/intro/arch_overview/upstream/health_checking#arch-overview-health-checking)），Endpoint 成为集群成员的持续时间（cluster membership duration）在慢启动时间窗口内
- 如果 cluster 配置了主动健康检测，Endpoint 通过了主动健康检测，且Endpoint 成为集群成员的持续时间在慢启动时间窗口内

Endpoint 退出慢启动的条件

- 离开集群
- 成为集群成员的持续时间超过了慢启动窗口
- 没有通过主动健康检测（如果 Endpoint 后续通过了主动健康检测并且它的创建时间在慢启动窗口内，它可以进一步重新进入慢启动）

> 虽然 Envoy 支持 active health checking，但是 istio 目前仍然不支持这方面的配置，可参考 https://github.com/istio/api/pull/2468，最近几周还有人提相关的 Pull Request。

不推荐对 cluster 开启慢启动模式的场景

- 流量很低
- 或者 Endpoints 很多

因为流量很低或者 Endpoints 很多的场景下，处于慢启动模式的 Endpoint 可能接收不到请求，或者达不到预热的效果（比如参考前面给出的 Endpoint 权重变化的曲线，如果 Endpoint 在预热期间只能接收到少数甚至个别请求，那对应时间点的权重连线画出来也没有曲线的效果了）。

### Istio 对慢启动（预热）的支持

Isito 支持在 DestinationRule 的 [LoadBalancerSettings](https://istio.io/latest/docs/reference/config/networking/destination-rule/#LoadBalancerSettings) 中配置 `warmupDurationSecs`，来生成对应的 Envoy 慢启动配置。

```yaml
apiVersion: networking.istio.io/v1beta1
kind: DestinationRule
metadata:
  name: 12345.httpbin
spec:
  host: 12345.httpbin.soa.mesh
  trafficPolicy:
    loadBalancer:
      simple: ROUND_ROBIN
      warmupDurationSecs: 300s
    connectionPool:
      tcp:
        maxConnections: 100
        connectTimeout: 500ms
```

例如上面的 DestinationRule 配置了 300s 的预热时长，对应到 Envoy 中的慢启动配置就是

![cluster config](/Users/zhongyuan/github/masquee/misc/istio-warm-up-demo/cluster config.png)

这里可以看到只配置了 `slow_start_window`，另外 2 个 slow start 的配置没法通过 istio 的 api 来进行配置，保持默认值（aggression为 1.0，流量线性增长，初始的比例为 10%）。

![istio_set_slow_start_config](/Users/zhongyuan/github/masquee/misc/istio-warm-up-demo/istio_set_slow_start_config.png)

下面通过实际测试，来看一下 endpoint 加入 cluster 之后接收到的流量变化情况。

创建 httpbin 的 4 个实例，初始时在 ServiceEntry 中配置 其中 3 个实例，并用 qps 为 200 发起请求

```bash
./fortio load -qps 200 -c 2 -t 10m -allow-initial-errors -H "Host:12345.httpbin.soa.mesh" http://1.1.1.1/get
```

然后修改 ServiceEntry，再增加一个实例，然后再从客户端来看发给该实例的请求数变化情况

```bash
for i in $(seq 1 400)
do
  curl localhost:15000/clusters -s | grep '12345.httpbin.soa.mesh::172.17.0.6:80::rq_total' >> stats.log ; sleep 1;
done
```

这里直接通过脚本，每秒获取发给新增实例的请求总数（脚本中的 IP 就是向 ServiceEntry 中新增加的 endpoint 的 IP）。然后根据统计数据，绘图看一下新实例接收到的请求数

总的请求数

![total requests](/Users/zhongyuan/github/masquee/misc/istio-warm-up-demo/total requests.png)



每秒请求数

![requests per second](/Users/zhongyuan/github/masquee/misc/istio-warm-up-demo/requests per second.png)

可以看出在预热期间，每秒的请求数基本上是线性增加的（也就是 Envoy 默认的 aggression 为 1.0 的效果），直到达到配置的预热时长后，每秒接收的请求数保持稳定在 50 个请求左右（qps 200，新实例加入后一共有 4 个实例，基本上每个实例接收到的 qps 就是 50 ） 。

### 总结

Envoy 虽然对预热提供了支持，且可以配置主动健康检测一起工作，但是 Istio 对预热的支持仍然不够完善，一方面不支持配置主动健康检测，另一方面对预热的配置只支持配置预热时长。不过即使只支持配置预热时长，后续升级 Istio 后也可以用起来，起码可以降低 soa operator 的复杂度（目前改的版本是预热期间每分钟修改实例权重），且减少控制面推送的压力。

另外需要注意的一点是，预热生效时间是 endpoint 加入 cluster 的时间开始算起，而按照我们目前的实现逻辑，拉出实例时会将 endpoint 从 ServiceEntry 中删除，这样的话后续拉入实例又会开始预热。
