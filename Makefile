
deploy-local:
	forge script script/FactoryV1Local.s.sol:FactoryV1LocalScript \
		--rpc-url http://localhost:8545 \
		--private-key $(or $(PRIVATE_KEY),0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80) \
		--broadcast -vvvv

deploy:
	forge script script/FactoryV1.s.sol:FactoryV1Script \
		--rpc-url $(RPC_URL) \
		--private-key $(PRIVATE_KEY) \
		--broadcast --verify -vvvv

new-token-sepolia:
	cast send 0xf33e6214867Ee20fbB3E9E01C1195243280036fB \
	  	"createToken(string,string,tuple(address,uint256)[])" \
  		"Root" "ROOT" \
  		"[(0x068842FCf7D6EB04255fe8BeB7224C0FE0506b92,100000000000000000000000000)]" \
  		--rpc-url $(RPC_URL) \
  		--private-key $(PRIVATE_KEY)
