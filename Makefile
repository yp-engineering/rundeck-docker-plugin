INSTALL_PATH?=
.PHONY: test

all: test clean zip

clean:
	rm -rf dist
	mkdir dist
zip:
	mkdir -p dist/docker
	cp -r docker/* dist/docker
	(cd dist; zip -r ../dist/docker.zip docker)
install: zip
	mv dist/docker.zip $(INSTALL_PATH)
test:
	ruby test/test_rundeck_docker_plugin.rb

