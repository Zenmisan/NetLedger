.PHONY: all test dev install install-service clean

all: test

test:
	@echo "Running NetLedger unit tests..."
	python3 -m unittest discover -s tests -v
	@echo "Validating Model.js with Node..."
	node -e "const fs = require('fs'); eval(fs.readFileSync('Model.js', 'utf8').replace('.pragma library', '')); console.log('Model.js syntax valid.');"
	@echo "Linting QML components..."
	qmllint BarWidget.qml Panel.qml

dev:
	@./install.sh --dev

install:
	@./install.sh

install-service:
	@./install.sh --service

clean:
	rm -rf __pycache__ tests/__pycache__ daemon/__pycache__ *.pyc
