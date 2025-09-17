from django.shortcuts import render, redirect
from django.contrib.auth import authenticate, login, logout
from django.contrib import messages
from .forms import SignUpForm


def login_view(request):
    if request.user.is_authenticated:
        return redirect("lecture:lecturers_list")

    if request.method == "POST":
        email = request.POST.get("email")
        password = request.POST.get("password")

        user = authenticate(request, username=email, password=password)
        if user is not None:
            login(request, user)
            next_url = request.GET.get("next", "lecture:lecturers_list")
            return redirect(next_url)
        else:
            messages.error(request, "Invalid email or password.")

    return render(request, "users/login.html")


def register_view(request):
    if request.user.is_authenticated:
        return redirect("lecture:lecturers_list")

    if request.method == "POST":
        form = SignUpForm(request.POST)
        if form.is_valid():
            form.save()
            messages.success(request, "Account created successfully! Please log in.")
            return redirect("users:login")
    else:
        form = SignUpForm()

    return render(request, "users/register.html", {"form": form})


def logout_view(request):
    logout(request)
    messages.success(request, "You have been logged out.")
    return redirect("users:login")
