INSTALL_PATH?=

all: clean zip

clean:
	rm -rf dist
	mkdir dist
zip:
	mkdir -p dist/docker
	cp -r docker/* dist/docker
	(cd dist; zip -r ../dist/docker.zip docker)
install: zip
	mv dist/docker.zip $(INSTALL_PATH)

