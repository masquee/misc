cd /tmp && touch stats.log
for i in $(seq 1 400)
do
  curl localhost:15000/clusters -s | grep '12345.httpbin.soa.mesh::172.17.0.6:80::rq_total' >> stats.log ; sleep 1;
done