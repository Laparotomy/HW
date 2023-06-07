print('Hello World')
x = input('Please input a value three-digit number: ')
y = int(x)
a = y%10
b = y//100
c = (y-b*100-a)//10
g = a*100+c*10+b
print(g)

