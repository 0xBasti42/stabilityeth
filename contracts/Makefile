include .env
export

install:
	forge install

build:
	forge build

test:
	forge test --show-progress

coverage:
	forge coverage --ir-minimum --report lcov

fmt:
	forge fmt

deploy-base-sepolia:
	@forge script ./script/Deploy.s.sol:DeployBaseSepolia --private-key $(PRIVATE_KEY) --rpc-url $(BASE_SEPOLIA_RPC_URL) --verify --etherscan-api-key ${BASESCAN_API_KEY} --broadcast --slow

deploy-base:
	@forge script ./script/Deploy.s.sol:DeployBase --private-key $(PRIVATE_KEY) --rpc-url $(BASE_MAINNET_RPC_URL) --verify --etherscan-api-key ${BASESCAN_API_KEY} --broadcast --slow