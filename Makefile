# Run project
run:
	poetry run python manage.py makemigrations
	poetry run python manage.py migrate
	poetry run python manage.py collectstatic --no-input --clear >> /dev/null
	poetry run python manage.py runserver

# Initialize initial data
init:
	poetry run python manage.py inituser
	poetry run python manage.py initcore

# Run migrations only
migrate:
	poetry run python manage.py makemigrations
	poetry run python manage.py migrate

# Run tests
test:
	poetry run python manage.py test

# Clean cache
clean:
	find . -type d -name "__pycache__" -exec rm -r {} +
	find . -type f -name "*.pyc" -delete

# Create superuser
superuser:
	poetry run python manage.py createsuperuser

# Code formatting and linting with auto-fix
check:
	poetry run black .
	poetry run ruff check . --fix

# Install dependencies with poetry
install:
	poetry install

# Activate virtual environment
shell:
	poetry shell
