<?xml version="1.0" encoding="UTF-8"?>
<xsl:stylesheet version="2.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform" xmlns:src="http://xmlns.example.com/oic/supplier-onboarding" xmlns:erp="http://xmlns.example.com/oic/erp/suppliers" exclude-result-prefixes="src erp">
   <xsl:param name="GetSupplierPayee" select="()"/>
   <xsl:param name="CreateBankAccount" select="()"/>
   <xsl:template match="/">
      <!-- Assign at supplier level: use the payee that has no supplier site -->
      <xsl:variable name="payees" select="$GetSupplierPayee/erp:PayeeQueryResponse/erp:items"/>
      <erp:InstrumentAssignment>
         <erp:PaymentPartyId><xsl:value-of select="($payees[not(normalize-space(erp:SupplierSiteCode))], $payees)[1]/erp:PayeeId"/></erp:PaymentPartyId>
         <erp:PaymentInstrumentId><xsl:value-of select="$CreateBankAccount/erp:ExternalBankAccount/erp:BankAccountId"/></erp:PaymentInstrumentId>
         <erp:PaymentInstrumentType>BANKACCOUNT</erp:PaymentInstrumentType>
         <erp:PrimaryIndicator>Y</erp:PrimaryIndicator>
         <erp:StartDate><xsl:value-of select="format-date(current-date(), '[Y0001]-[M01]-[D01]')"/></erp:StartDate>
      </erp:InstrumentAssignment>
   </xsl:template>
</xsl:stylesheet>
